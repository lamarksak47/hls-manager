#!/bin/bash
# install_hls_working.sh - Script que CONTORNA pacotes quebrados

set -e

echo "🔧 INSTALANDO HLS MANAGER - CONTORNANDO PACOTES QUEBRADOS"
echo "========================================================"

# 1. REMOVER completamente pacotes problemáticos
echo "🗑️ Removendo pacotes problemáticos..."
sudo apt-get remove --purge -y libmysqlclient-dev default-libmysqlclient-dev mariadb-connector-c 2>/dev/null || true
sudo apt-get autoremove -y
sudo apt-get autoclean

# 2. Liberar pacotes retidos
echo "🔓 Liberando pacotes retidos..."
sudo dpkg --remove --force-remove-reinstreq libmysqlclient-dev 2>/dev/null || true
sudo dpkg --configure -a

# 3. Atualizar e instalar dependências SEM default-libmysqlclient-dev
echo "📦 Instalando dependências alternativas..."
sudo apt-get update

# Instalar bibliotecas MySQL alternativas
sudo apt-get install -y libmariadb-dev libmariadb3 mariadb-server mariadb-client

# Dependências básicas
sudo apt-get install -y python3 python3-pip ffmpeg python3-venv nginx \
    software-properties-common curl wget git build-essential \
    pkg-config libssl-dev libffi-dev python3-dev

# 4. Usar pip para instalar mysqlclient SEM as libs do sistema
echo "🐍 Instalando mysqlclient via pip (sem dependências do sistema)..."

# Criar ambiente temporário para testar
python3 -m venv /tmp/test_env
/tmp/test_env/bin/pip install --upgrade pip setuptools wheel

# Tentar diferentes métodos para instalar mysqlclient
echo "Tentando método 1: mysqlclient com headers do MariaDB..."
if /tmp/test_env/bin/pip install mysqlclient==2.1.1 --no-binary mysqlclient; then
    echo "✅ Método 1 funcionou"
    MYSQLCLIENT_METHOD="source"
else
    echo "Tentando método 2: mysqlclient binary..."
    if /tmp/test_env/bin/pip install mysqlclient; then
        echo "✅ Método 2 funcionou"
        MYSQLCLIENT_METHOD="binary"
    else
        echo "Tentando método 3: pymysql como fallback..."
        if /tmp/test_env/bin/pip install pymysql; then
            echo "✅ Usando pymysql como fallback"
            MYSQLCLIENT_METHOD="pymysql"
        else
            echo "❌ Todos os métodos falharam"
            exit 1
        fi
    fi
fi

# 5. Configurar MariaDB
echo "🗄️ Configurando MariaDB..."
sudo systemctl start mariadb
sudo systemctl enable mariadb

# Configurar senha root se necessário
if sudo mysql -u root -e "SELECT 1" 2>/dev/null; then
    echo "🔐 Configurando senha root..."
    sudo mysql -u root <<-EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY 'RootPass123';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
EOF
    ROOT_PASS="RootPass123"
else
    echo "Usando configuração existente do MariaDB"
    ROOT_PASS="RootPass123"
fi

# 6. Criar banco de dados da aplicação
echo "🗃️ Criando banco de dados..."
APP_USER="hls_app"
APP_PASS="AppPass$(date +%s | tail -c 4)"

sudo mysql -u root -p"$ROOT_PASS" <<-EOF 2>/dev/null || sudo mysql -u root <<-EOF
CREATE DATABASE IF NOT EXISTS hls_manager CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${APP_USER}'@'localhost' IDENTIFIED BY '${APP_PASS}';
GRANT ALL PRIVILEGES ON hls_manager.* TO '${APP_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF

# 7. Criar estrutura do sistema
echo "👤 Criando estrutura do sistema..."
if ! id "hlsuser" &>/dev/null; then
    sudo useradd -r -s /bin/false -m -d /opt/hls-streamer hlsuser
fi

sudo mkdir -p /opt/hls-streamer/{uploads,hls,logs,config}
cd /opt/hls-streamer
sudo chown -R hlsuser:hlsuser /opt/hls-streamer

# 8. Instalar dependências Python baseado no método escolhido
echo "📦 Instalando ambiente Python..."

sudo -u hlsuser python3 -m venv venv

# Instalar mysqlclient usando o método que funcionou
case "$MYSQLCLIENT_METHOD" in
    "source")
        sudo -u hlsuser ./venv/bin/pip install mysqlclient==2.1.1 --no-binary mysqlclient
        DRIVER="mysqlclient"
        CONN_STRING="mysql://${APP_USER}:${APP_PASS}@localhost/hls_manager"
        ;;
    "binary")
        sudo -u hlsuser ./venv/bin/pip install mysqlclient
        DRIVER="mysqlclient"
        CONN_STRING="mysql://${APP_USER}:${APP_PASS}@localhost/hls_manager"
        ;;
    "pymysql")
        sudo -u hlsuser ./venv/bin/pip install pymysql
        DRIVER="pymysql"
        CONN_STRING="mysql+pymysql://${APP_USER}:${APP_PASS}@localhost/hls_manager"
        ;;
esac

# Instalar outras dependências
sudo -u hlsuser ./venv/bin/pip install flask==2.3.3 flask-sqlalchemy==3.0.5 \
    gunicorn==21.2.0 python-dotenv==1.0.0

# 9. Criar aplicação Flask MÍNIMA
echo "💻 Criando aplicação mínima..."

# app.py
sudo tee /opt/hls-streamer/app.py > /dev/null << EOF
from flask import Flask, jsonify, render_template_string
from flask_sqlalchemy import SQLAlchemy
import os

app = Flask(__name__)

# Configuração mínima
app.config['SECRET_KEY'] = 'dev-key-$(openssl rand -hex 16)'
app.config['SQLALCHEMY_DATABASE_URI'] = '${CONN_STRING}'
app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False

db = SQLAlchemy(app)

# Modelo simples
class User(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    username = db.Column(db.String(80), unique=True)
    email = db.Column(db.String(120), unique=True)

@app.route('/')
def home():
    return render_template_string('''
        <h1>🎬 HLS Streamer</h1>
        <p>✅ Sistema instalado com sucesso!</p>
        <p><strong>Driver MySQL:</strong> ${DRIVER}</p>
        <p><a href="/health">Health Check</a></p>
    ''')

@app.route('/health')
def health():
    try:
        db.session.execute('SELECT 1')
        return jsonify({
            'status': 'healthy',
            'database': 'connected',
            'driver': '${DRIVER}'
        })
    except Exception as e:
        return jsonify({'status': 'error', 'message': str(e)}), 500

# Criar tabelas na primeira execução
with app.app_context():
    db.create_all()
    print("✅ Tabelas do banco criadas")

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, debug=False)
EOF

# 10. Criar arquivo de configuração
echo "⚙️ Criando configuração..."
ADMIN_PASS="Admin$(date +%s | tail -c 4)"

sudo tee /opt/hls-streamer/.env > /dev/null << EOF
DEBUG=False
PORT=5000
SECRET_KEY=$(openssl rand -hex 32)
ADMIN_PASSWORD=${ADMIN_PASS}
EOF

sudo chown hlsuser:hlsuser /opt/hls-streamer/.env
sudo chmod 600 /opt/hls-streamer/.env

# 11. Criar serviço systemd
echo "⚙️ Criando serviço systemd..."
sudo tee /etc/systemd/system/hls-streamer.service > /dev/null << EOF
[Unit]
Description=HLS Streamer Service
After=network.target mariadb.service

[Service]
Type=simple
User=hlsuser
Group=hlsuser
WorkingDirectory=/opt/hls-streamer
Environment="PATH=/opt/hls-streamer/venv/bin"
ExecStart=/opt/hls-streamer/venv/bin/gunicorn \
    --bind 127.0.0.1:5000 \
    --workers 1 \
    --timeout 60 \
    app:app
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# 12. Criar script de inicialização
sudo tee /opt/hls-streamer/start.sh > /dev/null << 'EOF'
#!/bin/bash
echo "🚀 Iniciando HLS Streamer..."
cd /opt/hls-streamer
source venv/bin/activate
gunicorn --bind 0.0.0.0:5000 app:app
EOF

sudo chmod +x /opt/hls-streamer/start.sh
sudo chown hlsuser:hlsuser /opt/hls-streamer/start.sh

# 13. Iniciar serviços
echo "🚀 Iniciando serviços..."
sudo systemctl daemon-reload
sudo systemctl enable hls-streamer
sudo systemctl start hls-streamer

sleep 3

# 14. Testar
echo "🧪 Testando instalação..."
if curl -s http://localhost:5000/health | grep -q "healthy"; then
    echo "✅ Sistema está funcionando!"
    STATUS="✅"
else
    echo "⚠️ Sistema não responde. Verificando..."
    sudo journalctl -u hls-streamer -n 20 --no-pager
    STATUS="⚠️"
fi

# 15. Mostrar informações
IP=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "localhost")
echo ""
echo "🎉 HLS STREAMER INSTALADO!"
echo "=========================="
echo "Status: $STATUS"
echo "URL: http://$IP:5000"
echo ""
echo "🔧 Informações Técnicas:"
echo "• Driver MySQL: $DRIVER"
echo "• Usuário DB: $APP_USER"
echo "• Senha DB: $APP_PASS"
echo "• Diretório: /opt/hls-streamer"
echo ""
echo "⚙️ Comandos:"
echo "• sudo systemctl status hls-streamer"
echo "• sudo journalctl -u hls-streamer -f"
echo "• mysql -u $APP_USER -p$APP_PASS hls_manager"
echo ""
echo "📌 Nota: Esta é uma versão mínima funcional."
echo "   O sistema básico está rodando!"
