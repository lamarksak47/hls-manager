#!/bin/bash
# install_hls_manager_corrected.sh - Script CORRIGIDO para MariaDB com senha

set -e

echo "🎬 INSTALANDO HLS MANAGER - VERSÃO CORRIGIDA"
echo "==========================================="

# 1. Verificar e corrigir pacotes
echo "🔧 Preparando sistema..."
sudo apt-get update
sudo apt-get install -f -y
sudo dpkg --configure -a

# 2. Dependências essenciais (SEM bibliotecas MySQL problemáticas)
echo "📦 Instalando dependências seguras..."
sudo apt-get install -y python3 python3-pip ffmpeg python3-venv nginx \
    software-properties-common curl wget git \
    pkg-config libssl-dev libffi-dev python3-dev sqlite3

# 3. VERIFICAR MariaDB e obter senha CORRETA
echo "🔍 Detectando configuração do MariaDB..."

# Tentar diferentes métodos para conectar ao MariaDB
ROOT_PASS=""

# Método 1: Tentar sem senha
if sudo mysql -u root -e "SELECT 1" 2>/dev/null; then
    echo "✅ MariaDB acessível sem senha"
    ROOT_PASS=""
    
# Método 2: Tentar senha padrão do script anterior
elif sudo mysql -u root -pRootPass123 -e "SELECT 1" 2>/dev/null; then
    echo "✅ Usando senha padrão: RootPass123"
    ROOT_PASS="RootPass123"
    
# Método 3: Tentar senha do MariaDB RootPass@2024
elif sudo mysql -u root -p'MariaDBRootPass@2024' -e "SELECT 1" 2>/dev/null; then
    echo "✅ Usando senha: MariaDBRootPass@2024"
    ROOT_PASS="MariaDBRootPass@2024"
    
# Método 4: Pedir senha ao usuário
else
    echo ""
    echo "⚠️ ATENÇÃO: MariaDB já foi configurado com senha personalizada"
    echo "=========================================================="
    echo "Por favor, digite a senha do usuário ROOT do MariaDB:"
    echo "(Pressione Enter se não souber - tentaremos redefinir)"
    echo "=========================================================="
    read -s USER_PASS
    
    if [ -n "$USER_PASS" ]; then
        if sudo mysql -u root -p"$USER_PASS" -e "SELECT 1" 2>/dev/null; then
            ROOT_PASS="$USER_PASS"
            echo "✅ Senha correta!"
        else
            echo "❌ Senha incorreta. Vamos redefinir..."
            ROOT_PASS=""
        fi
    fi
fi

# 4. Se não temos senha válida, REINICIAR configuração do MariaDB
if [ -z "$ROOT_PASS" ]; then
    echo "🔄 Reconfigurando MariaDB..."
    
    # Parar MariaDB
    sudo systemctl stop mariadb 2>/dev/null || true
    
    # Método SEGURO: Usar mysql_secure_installation interativo
    echo "Executando configuração segura do MariaDB..."
    echo "Siga as instruções abaixo:"
    echo ""
    echo "1. Pressione ENTER para senha atual (vazia)"
    echo "2. Digite 'Y' para definir nova senha"
    echo "3. Escolha uma senha forte (ex: MariaDBRoot@2024)"
    echo "4. Confirme a senha"
    echo "5. Responda 'Y' para todas as perguntas de segurança"
    echo ""
    echo "Pressione Enter para começar..."
    read
    
    sudo mysql_secure_installation
    
    # Testar com senha padrão após reconfiguração
    ROOT_PASS="MariaDBRoot@2024"
fi

# 5. Criar banco de dados da aplicação
echo "🗃️ Criando banco de dados da aplicação..."
APP_USER="hls_app"
APP_PASS="App_$(date +%s | tail -c 6)"

# Função para executar SQL com a senha correta
execute_mysql() {
    local sql="$1"
    
    if [ -n "$ROOT_PASS" ]; then
        sudo mysql -u root -p"$ROOT_PASS" -e "$sql" 2>/dev/null && return 0
    fi
    
    # Tentar sem senha
    sudo mysql -u root -e "$sql" 2>/dev/null && return 0
    
    return 1
}

# Comandos SQL para criar banco
SQL_COMMANDS="
CREATE DATABASE IF NOT EXISTS hls_manager CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${APP_USER}'@'localhost' IDENTIFIED BY '${APP_PASS}';
GRANT ALL PRIVILEGES ON hls_manager.* TO '${APP_USER}'@'localhost';
FLUSH PRIVILEGES;
"

if execute_mysql "$SQL_COMMANDS"; then
    echo "✅ Banco de dados criado com sucesso!"
else
    echo "⚠️ Erro ao criar banco. Tentando método alternativo..."
    
    # Método alternativo: conectar e executar manualmente
    if [ -n "$ROOT_PASS" ]; then
        sudo mysql -u root -p"$ROOT_PASS" <<-EOF
CREATE DATABASE IF NOT EXISTS hls_manager;
CREATE USER IF NOT EXISTS '${APP_USER}'@'localhost' IDENTIFIED BY '${APP_PASS}';
GRANT ALL PRIVILEGES ON hls_manager.* TO '${APP_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF
    else
        sudo mysql -u root <<-EOF
CREATE DATABASE IF NOT EXISTS hls_manager;
CREATE USER IF NOT EXISTS '${APP_USER}'@'localhost' IDENTIFIED BY '${APP_PASS}';
GRANT ALL PRIVILEGES ON hls_manager.* TO '${APP_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF
    fi
    
    echo "✅ Banco criado via método alternativo"
fi

# 6. USAR SQLite como FALLBACK se MySQL falhar
echo "🔧 Verificando conexão com banco..."
if ! sudo mysql -u "$APP_USER" -p"$APP_PASS" -e "USE hls_manager; SELECT 1" 2>/dev/null; then
    echo "⚠️ Não foi possível conectar ao MySQL/MariaDB"
    echo "📊 Usando SQLite como banco de dados alternativo..."
    USE_SQLITE=true
    DB_STRING="sqlite:////opt/hls-manager/hls.db"
else
    USE_SQLITE=false
    DB_STRING="mysql://${APP_USER}:${APP_PASS}@localhost/hls_manager"
    echo "✅ Conexão MySQL estabelecida"
fi

# 7. Criar estrutura do sistema
echo "👤 Criando estrutura do sistema..."
if ! id "hlsadmin" &>/dev/null; then
    sudo useradd -r -s /bin/false -m -d /opt/hls-manager hlsadmin
fi

sudo mkdir -p /opt/hls-manager/{uploads,hls,logs,config,static}
cd /opt/hls-manager

# Configurar permissões
sudo chown -R hlsadmin:hlsadmin /opt/hls-manager
sudo chmod 755 /opt/hls-manager
sudo chmod 770 /opt/hls-manager/uploads

# 8. Configurar ambiente Python com PyMySQL (mais confiável)
echo "🐍 Configurando ambiente Python com PyMySQL..."

sudo -u hlsadmin python3 -m venv venv

# Atualizar pip
sudo -u hlsadmin ./venv/bin/pip install --upgrade pip setuptools wheel

# Instalar PyMySQL (funciona sem bibliotecas C do sistema)
if [ "$USE_SQLITE" = false ]; then
    echo "Instalando PyMySQL para MySQL..."
    sudo -u hlsadmin ./venv/bin/pip install pymysql
    DRIVER="pymysql"
else
    echo "Usando SQLite (não requer driver adicional)"
    DRIVER="sqlite"
fi

# Instalar Flask e dependências básicas
sudo -u hlsadmin ./venv/bin/pip install flask==2.3.3 \
    flask-sqlalchemy==3.0.5 \
    flask-login==0.6.2 \
    flask-wtf==1.1.1 \
    gunicorn==21.2.0 \
    python-dotenv==1.0.0 \
    werkzeug==2.3.7

# 9. Criar aplicação Flask adaptativa
echo "💻 Criando aplicação adaptativa..."

# app.py adaptativo
sudo tee /opt/hls-manager/app.py > /dev/null << EOF
from flask import Flask, jsonify, render_template_string
from flask_sqlalchemy import SQLAlchemy
from flask_login import LoginManager, UserMixin, login_user, logout_user, login_required
import os
from datetime import datetime

app = Flask(__name__)

# Configuração adaptativa
app.config['SECRET_KEY'] = os.getenv('SECRET_KEY', 'dev-secret-key-12345')

if os.getenv('DB_TYPE', 'mysql') == 'sqlite':
    app.config['SQLALCHEMY_DATABASE_URI'] = 'sqlite:////opt/hls-manager/hls.db'
    print("📊 Usando SQLite como banco de dados")
else:
    db_user = os.getenv('DB_USER', 'hls_app')
    db_pass = os.getenv('DB_PASS', '')
    app.config['SQLALCHEMY_DATABASE_URI'] = f'mysql+pymysql://{db_user}:{db_pass}@localhost/hls_manager'
    print("📊 Usando MySQL/MariaDB como banco de dados")

app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False

db = SQLAlchemy(app)
login_manager = LoginManager(app)

# Modelos
class User(UserMixin, db.Model):
    id = db.Column(db.Integer, primary_key=True)
    username = db.Column(db.String(80), unique=True, nullable=False)
    email = db.Column(db.String(120), unique=True, nullable=False)
    password_hash = db.Column(db.String(200))
    is_admin = db.Column(db.Boolean, default=False)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    
    def __repr__(self):
        return f'<User {self.username}>'

class Channel(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(100), nullable=False)
    description = db.Column(db.Text)
    status = db.Column(db.String(20), default='draft')
    hls_path = db.Column(db.String(500))
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    
    def __repr__(self):
        return f'<Channel {self.name}>'

@login_manager.user_loader
def load_user(user_id):
    return User.query.get(int(user_id))

# Rotas
@app.route('/')
def index():
    db_type = 'SQLite' if 'sqlite' in app.config['SQLALCHEMY_DATABASE_URI'] else 'MySQL/MariaDB'
    
    return render_template_string('''
        <!DOCTYPE html>
        <html>
        <head>
            <title>🎬 HLS Manager</title>
            <style>
                body { font-family: Arial, sans-serif; margin: 40px; background: #f5f5f5; }
                .container { max-width: 800px; margin: 0 auto; background: white; padding: 30px; border-radius: 10px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
                .success { color: #28a745; font-weight: bold; }
                .info { color: #17a2b8; }
                .btn { display: inline-block; padding: 10px 20px; background: #007bff; color: white; text-decoration: none; border-radius: 5px; margin: 10px 5px; }
            </style>
        </head>
        <body>
            <div class="container">
                <h1>🎬 HLS Manager</h1>
                <p class="success">✅ Sistema instalado e funcionando!</p>
                
                <h2>Informações do Sistema</h2>
                <p><strong>Banco de Dados:</strong> {{ db_type }}</p>
                <p><strong>Status:</strong> <span class="success">Operacional</span></p>
                
                <h2>Ações</h2>
                <a href="/dashboard" class="btn">📊 Dashboard</a>
                <a href="/health" class="btn">❤️ Health Check</a>
                <a href="/channels" class="btn">📺 Canais</a>
                
                <h2>Próximos Passos</h2>
                <ol>
                    <li>Acesse o Dashboard para gerenciar canais</li>
                    <li>Configure o upload de vídeos</li>
                    <li>Monitore as conversões HLS</li>
                </ol>
            </div>
        </body>
        </html>
    ''', db_type=db_type)

@app.route('/dashboard')
@login_required
def dashboard():
    channels = Channel.query.count()
    return f'<h1>Dashboard</h1><p>Canais: {channels}</p>'

@app.route('/channels')
def channels():
    all_channels = Channel.query.all()
    channels_list = '<br>'.join([f'- {c.name} ({c.status})' for c in all_channels])
    return f'<h1>Canais</h1><p>{channels_list}</p>'

@app.route('/health')
def health():
    try:
        db.session.execute('SELECT 1')
        return jsonify({
            'status': 'healthy',
            'database': 'connected',
            'service': 'hls-manager',
            'timestamp': datetime.utcnow().isoformat()
        })
    except Exception as e:
        return jsonify({
            'status': 'unhealthy',
            'error': str(e),
            'database': 'disconnected'
        }), 500

# Criar tabelas
with app.app_context():
    db.create_all()
    print("✅ Tabelas do banco criadas/verificadas")
    
    # Criar usuário admin se não existir
    if not User.query.filter_by(username='admin').first():
        from werkzeug.security import generate_password_hash
        admin = User(
            username='admin',
            email='admin@localhost',
            password_hash=generate_password_hash(os.getenv('ADMIN_PASS', 'Admin123')),
            is_admin=True
        )
        db.session.add(admin)
        db.session.commit()
        print("✅ Usuário admin criado")

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, debug=False)
EOF

# 10. Criar arquivo de configuração
echo "⚙️ Criando configuração..."
ADMIN_PASS="Admin$(date +%s | tail -c 6)"
SECRET_KEY=$(openssl rand -hex 32)

sudo tee /opt/hls-manager/.env > /dev/null << EOF
# HLS Manager Configuration
DEBUG=False
PORT=5000
HOST=0.0.0.0
SECRET_KEY=${SECRET_KEY}

# Database Configuration
DB_TYPE=${DRIVER}
DB_USER=${APP_USER}
DB_PASS=${APP_PASS}

# Admin User
ADMIN_USERNAME=admin
ADMIN_PASSWORD=${ADMIN_PASS}

# Paths
UPLOAD_FOLDER=/opt/hls-manager/uploads
HLS_FOLDER=/opt/hls-manager/hls
LOG_FOLDER=/opt/hls-manager/logs

# Limits
MAX_UPLOAD_SIZE=1073741824  # 1GB
EOF

sudo chown hlsadmin:hlsadmin /opt/hls-manager/.env
sudo chmod 600 /opt/hls-manager/.env

# 11. Criar sistema de serviço
echo "⚙️ Configurando sistema de serviço..."

# systemd service
sudo tee /etc/systemd/system/hls-manager.service > /dev/null << EOF
[Unit]
Description=HLS Manager Service
After=network.target

[Service]
Type=simple
User=hlsadmin
Group=hlsadmin
WorkingDirectory=/opt/hls-manager
Environment="PATH=/opt/hls-manager/venv/bin"
Environment="FLASK_APP=app.py"
ExecStart=/opt/hls-manager/venv/bin/gunicorn \
    --bind 127.0.0.1:5000 \
    --workers 2 \
    --threads 2 \
    --timeout 120 \
    app:app
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# 12. Configurar Nginx
echo "🌐 Configurando Nginx..."

sudo tee /etc/nginx/sites-available/hls-manager > /dev/null << 'EOF'
server {
    listen 80;
    server_name _;
    
    # Tamanho máximo de upload
    client_max_body_size 1G;
    
    # Proxy para aplicação
    location / {
        proxy_pass http://127.0.0.1:5000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        
        # Timeouts
        proxy_connect_timeout 60s;
        proxy_send_timeout 300s;
        proxy_read_timeout 300s;
    }
    
    # Servir arquivos HLS
    location /hls/ {
        alias /opt/hls-manager/hls/;
        expires 30d;
        add_header Cache-Control "public";
    }
    
    # Health check
    location /health {
        proxy_pass http://127.0.0.1:5000/health;
        access_log off;
    }
}
EOF

sudo ln -sf /etc/nginx/sites-available/hls-manager /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true

# 13. Iniciar serviços
echo "🚀 Iniciando serviços..."

sudo systemctl daemon-reload

# Iniciar MariaDB se estiver usando MySQL
if [ "$USE_SQLITE" = false ]; then
    sudo systemctl restart mariadb
    sleep 2
fi

# Iniciar aplicação
sudo systemctl enable hls-manager
sudo systemctl start hls-manager
sleep 3

# Iniciar Nginx
sudo nginx -t 2>/dev/null && sudo systemctl restart nginx

# 14. Testar instalação
echo "🧪 Testando instalação..."
sleep 5

echo "Verificando status dos serviços:"

# Verificar hls-manager
if sudo systemctl is-active --quiet hls-manager; then
    echo "✅ hls-manager: ATIVO"
    
    # Testar endpoint de saúde
    if curl -s http://localhost:5000/health 2>/dev/null | grep -q "healthy"; then
        echo "✅ Aplicação: RESPONDENDO"
        APP_STATUS="✅"
    else
        echo "⚠️ Aplicação: NÃO RESPONDE"
        APP_STATUS="⚠️"
    fi
else
    echo "❌ hls-manager: INATIVO"
    APP_STATUS="❌"
fi

# Verificar Nginx
if sudo systemctl is-active --quiet nginx; then
    echo "✅ nginx: ATIVO"
    NGINX_STATUS="✅"
else
    echo "❌ nginx: INATIVO"
    NGINX_STATUS="❌"
fi

# 15. Mostrar informações finais
IP=$(hostname -I | awk '{print $1}' 2>/dev/null || curl -s ifconfig.me || echo "localhost")

echo ""
echo "🎉 HLS MANAGER INSTALADO!"
echo "========================"
echo "Status da Instalação:"
echo "• Aplicação: $APP_STATUS"
echo "• Nginx: $NGINX_STATUS"
echo "• Banco de Dados: $DRIVER"
echo ""
echo "🌐 URL DE ACESSO:"
echo "   http://$IP"
echo ""
echo "🔐 CREDENCIAIS:"
echo "   Usuário: admin"
echo "   Senha: $ADMIN_PASS"
echo ""
if [ "$USE_SQLITE" = false ]; then
    echo "🗄️ BANCO DE DADOS (MySQL/MariaDB):"
    echo "   Usuário: $APP_USER"
    echo "   Senha: $APP_PASS"
    echo "   Banco: hls_manager"
else
    echo "🗄️ BANCO DE DADOS: SQLite"
    echo "   Arquivo: /opt/hls-manager/hls.db"
fi
echo ""
echo "⚙️ COMANDOS ÚTEIS:"
echo "• Ver status: sudo systemctl status hls-manager"
echo "• Ver logs: sudo journalctl -u hls-manager -f"
echo "• Reiniciar: sudo systemctl restart hls-manager"
echo ""
echo "📁 DIRETÓRIO: /opt/hls-manager"
echo "✅ Instalação concluída!"
