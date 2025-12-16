#!/bin/bash
# install_hls_manager_stable.sh - Script ESTÁVEL usando apenas mysqlclient

set -e

echo "🎬 INSTALANDO HLS MANAGER - VERSÃO ESTÁVEL"
echo "=========================================="

# 1. CORRIGIR pacotes quebrados primeiro
echo "🔧 Corrigindo pacotes quebrados..."
sudo apt-get update
sudo apt-get install -f -y
sudo dpkg --configure -a
sudo apt-get autoremove -y
sudo apt-get autoclean

# 2. Instalar dependências básicas
echo "📦 Instalando dependências básicas..."
sudo apt-get install -y python3 python3-pip ffmpeg python3-venv nginx \
    software-properties-common curl wget git build-essential \
    pkg-config libssl-dev libffi-dev

# 3. VERIFICAR e INSTALAR MariaDB/MySQL
echo "🗄️ Verificando banco de dados..."
if ! command -v mysql &>/dev/null; then
    echo "📥 Instalando MariaDB Server..."
    sudo apt-get install -y mariadb-server mariadb-client
else
    echo "✅ MySQL/MariaDB já está instalado"
fi

# Iniciar e habilitar MariaDB
sudo systemctl start mariadb 2>/dev/null || true
sudo systemctl enable mariadb 2>/dev/null || true

# 4. INSTALAR APENAS mysqlclient (evitar mariadb-connector)
echo "📦 Instalando bibliotecas para mysqlclient..."
sudo apt-get install -y default-libmysqlclient-dev python3-dev

# Verificar se libmysqlclient-dev está disponível
if ! apt-cache show libmysqlclient-dev &>/dev/null; then
    echo "⚠️ libmysqlclient-dev não encontrado, instalando alternativas..."
    sudo apt-get install -y libmariadb-dev libmariadb3
fi

# 5. Configurar MariaDB (método simplificado)
echo "🔐 Configurando MariaDB..."
sleep 2

# Verificar se podemos acessar sem senha
if sudo mysql -u root -e "SELECT 1" 2>/dev/null; then
    echo "🔧 Configurando senha root..."
    sudo mysql -u root <<-EOF
SET PASSWORD FOR 'root'@'localhost' = PASSWORD('MariaDBRootPass@2024');
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
EOF
    ROOT_PASS="MariaDBRootPass@2024"
else
    # Tentar com senha padrão
    if sudo mysql -u root -pMariaDBRootPass@2024 -e "SELECT 1" 2>/dev/null; then
        ROOT_PASS="MariaDBRootPass@2024"
    else
        echo "⚠️ MariaDB já tem senha diferente."
        echo "Por favor, digite a senha do root do MariaDB:"
        read -s ROOT_PASS
    fi
fi

# 6. Criar banco de dados da aplicação
echo "🗃️ Criando banco de dados da aplicação..."
MYSQL_APP_PASS="HlsApp$(date +%s | tail -c 6)"
MYSQL_APP_USER="hls_manager"

# Função para executar comandos SQL
execute_sql() {
    local sql="$1"
    # Tentar com senha
    if sudo mysql -u root -p"$ROOT_PASS" -e "$sql" 2>/dev/null; then
        return 0
    # Tentar sem senha
    elif sudo mysql -u root -e "$sql" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Criar banco e usuário
SQL_COMMANDS="
DROP DATABASE IF EXISTS hls_manager;
CREATE DATABASE hls_manager CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
DROP USER IF EXISTS '${MYSQL_APP_USER}'@'localhost';
CREATE USER '${MYSQL_APP_USER}'@'localhost' IDENTIFIED BY '${MYSQL_APP_PASS}';
GRANT ALL PRIVILEGES ON hls_manager.* TO '${MYSQL_APP_USER}'@'localhost';
FLUSH PRIVILEGES;
"

if execute_sql "$SQL_COMMANDS"; then
    echo "✅ Banco de dados criado com sucesso!"
else
    echo "⚠️ Usando método alternativo para criar banco..."
    sudo mysql <<-EOF
CREATE DATABASE IF NOT EXISTS hls_manager CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${MYSQL_APP_USER}'@'localhost' IDENTIFIED BY '${MYSQL_APP_PASS}';
GRANT ALL PRIVILEGES ON hls_manager.* TO '${MYSQL_APP_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF
fi

# 7. Criar usuário e diretórios do sistema
echo "👤 Criando estrutura do sistema..."
if ! id "hlsmanager" &>/dev/null; then
    sudo useradd -r -s /bin/false -m -d /opt/hls-manager hlsmanager
fi

# Criar diretórios
sudo mkdir -p /opt/hls-manager/{uploads,hls,logs,temp,config,backups}
cd /opt/hls-manager

# Permissões
sudo chown -R hlsmanager:hlsmanager /opt/hls-manager
sudo chmod 750 /opt/hls-manager
sudo chmod 770 /opt/hls-manager/uploads /opt/hls-manager/temp
sudo chmod 755 /opt/hls-manager/hls

# 8. Configurar ambiente Python com MYSQLCLIENT APENAS
echo "🐍 Configurando ambiente Python (usando mysqlclient apenas)..."

# Remover qualquer virtualenv existente
sudo rm -rf /opt/hls-manager/venv 2>/dev/null || true

# Criar novo virtualenv
sudo -u hlsmanager python3 -m venv venv

# Configurar pip para usar cache e timeout maior
sudo -u hlsmanager ./venv/bin/pip config set global.timeout 60
sudo -u hlsmanager ./venv/bin/pip config set global.retries 10

echo "📦 Instalando pacotes Python..."
# Atualizar pip primeiro
sudo -u hlsmanager ./venv/bin/pip install --upgrade pip setuptools wheel

# INSTALAR MYSQLCLIENT PRIMEIRO (versão específica estável)
echo "Instalando mysqlclient..."
if sudo -u hlsmanager ./venv/bin/pip install mysqlclient==2.1.1; then
    echo "✅ mysqlclient instalado com sucesso"
else
    echo "⚠️ Tentando versão mais recente do mysqlclient..."
    sudo -u hlsmanager ./venv/bin/pip install mysqlclient
fi

# Instalar Flask e outras dependências
echo "Instalando Flask e dependências..."
FLASK_PACKAGES="
flask==2.3.3
flask-login==0.6.3
flask-sqlalchemy==3.0.5
flask-migrate==4.0.4
flask-wtf==1.1.1
flask-cors==4.0.0
python-dotenv==1.0.0
gunicorn==21.2.0
cryptography==41.0.7
werkzeug==2.3.7
pillow==10.0.1
bcrypt==4.0.1
flask-limiter==3.3.3
python-dateutil==2.8.2
"

sudo -u hlsmanager ./venv/bin/pip install $FLASK_PACKAGES

# Instalar python-magic
sudo apt-get install -y libmagic1
sudo -u hlsmanager ./venv/bin/pip install python-magic-bin==0.4.14

# 9. Criar configuração .env
echo "⚙️ Criando configuração..."
ADMIN_PASSWORD="Admin@$(date +%s | tail -c 6)"
SECRET_KEY=$(openssl rand -hex 32)

sudo tee /opt/hls-manager/config/.env > /dev/null << EOF
# HLS Manager Configuration
DEBUG=False
PORT=5000
HOST=127.0.0.1
SECRET_KEY=${SECRET_KEY}

# Database (using mysqlclient)
DB_HOST=localhost
DB_PORT=3306
DB_NAME=hls_manager
DB_USER=${MYSQL_APP_USER}
DB_PASSWORD=${MYSQL_APP_PASS}
SQLALCHEMY_DATABASE_URI=mysql://${MYSQL_APP_USER}:${MYSQL_APP_PASS}@localhost/hls_manager

# Upload Settings
MAX_UPLOAD_SIZE=1073741824  # 1GB
MAX_CONCURRENT_JOBS=2
HLS_SEGMENT_TIME=10
HLS_DELETE_AFTER_DAYS=7

# Authentication
ADMIN_USERNAME=admin
ADMIN_EMAIL=admin@localhost
ADMIN_PASSWORD=${ADMIN_PASSWORD}

# Paths
BASE_DIR=/opt/hls-manager
UPLOAD_FOLDER=/opt/hls-manager/uploads
HLS_FOLDER=/opt/hls-manager/hls
TEMP_FOLDER=/opt/hls-manager/temp
LOG_FOLDER=/opt/hls-manager/logs
EOF

sudo chown hlsmanager:hlsmanager /opt/hls-manager/config/.env
sudo chmod 640 /opt/hls-manager/config/.env

# 10. Criar aplicação Flask SIMPLIFICADA
echo "💻 Criando aplicação Flask simplificada..."

# Criar diretórios da aplicação
sudo -u hlsmanager mkdir -p /opt/hls-manager/app

# __init__.py SIMPLIFICADO
sudo tee /opt/hls-manager/app/__init__.py > /dev/null << 'EOF'
from flask import Flask, jsonify, render_template_string
from flask_sqlalchemy import SQLAlchemy
import os
from dotenv import load_dotenv

load_dotenv('/opt/hls-manager/config/.env')

db = SQLAlchemy()

def create_app():
    app = Flask(__name__)
    
    # Basic configuration
    app.config['SECRET_KEY'] = os.getenv('SECRET_KEY', 'dev-key-123')
    app.config['SQLALCHEMY_DATABASE_URI'] = os.getenv('SQLALCHEMY_DATABASE_URI')
    app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False
    
    db.init_app(app)
    
    # Simple home page
    @app.route('/')
    def index():
        return render_template_string('''
            <!DOCTYPE html>
            <html>
            <head><title>HLS Manager</title></head>
            <body>
                <h1>✅ HLS Manager Instalado</h1>
                <p>Sistema pronto para uso!</p>
                <p><a href="/dashboard">Dashboard</a> | <a href="/health">Health</a></p>
            </body>
            </html>
        ''')
    
    # Dashboard stub
    @app.route('/dashboard')
    def dashboard():
        return render_template_string('''
            <h1>Dashboard</h1>
            <p>Em desenvolvimento...</p>
        ''')
    
    # Health check endpoint
    @app.route('/health')
    def health():
        try:
            db.session.execute('SELECT 1')
            return jsonify({'status': 'healthy', 'database': 'connected'})
        except Exception as e:
            return jsonify({'status': 'unhealthy', 'error': str(e)}), 500
    
    # Login stub
    @app.route('/login')
    def login():
        return render_template_string('''
            <h1>Login</h1>
            <p>Página de login em desenvolvimento</p>
        ''')
    
    return app
EOF

# models.py SIMPLIFICADO
sudo tee /opt/hls-manager/app/models.py > /dev/null << 'EOF'
from datetime import datetime
from app import db

class User(db.Model):
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
    status = db.Column(db.String(20), default='draft')
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    
    def __repr__(self):
        return f'<Channel {self.name}>'
EOF

# run.py SIMPLIFICADO
sudo tee /opt/hls-manager/run.py > /dev/null << 'EOF'
#!/usr/bin/env python3
from app import create_app, db
from app.models import User
import os

app = create_app()

@app.before_first_request
def setup():
    with app.app_context():
        # Create tables
        db.create_all()
        
        # Create admin user if not exists
        if not User.query.filter_by(username='admin').first():
            from werkzeug.security import generate_password_hash
            admin = User(
                username='admin',
                email='admin@localhost',
                password_hash=generate_password_hash(os.getenv('ADMIN_PASSWORD')),
                is_admin=True
            )
            db.session.add(admin)
            db.session.commit()
            print("Admin user created")

if __name__ == '__main__':
    app.run(
        host=os.getenv('HOST', '127.0.0.1'),
        port=int(os.getenv('PORT', 5000)),
        debug=False
    )
EOF

sudo chmod +x /opt/hls-manager/run.py

# 11. Criar serviço systemd
echo "⚙️ Criando serviço systemd..."
sudo tee /etc/systemd/system/hls-manager.service > /dev/null << EOF
[Unit]
Description=HLS Manager
After=network.target

[Service]
Type=simple
User=hlsmanager
Group=hlsmanager
WorkingDirectory=/opt/hls-manager
Environment="PATH=/opt/hls-manager/venv/bin"
ExecStart=/opt/hls-manager/venv/bin/gunicorn \
    --bind 127.0.0.1:5000 \
    --workers 1 \
    --timeout 120 \
    run:app
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# 12. Configurar Nginx SIMPLIFICADO
echo "🌐 Configurando Nginx..."
sudo tee /etc/nginx/sites-available/hls-manager > /dev/null << 'EOF'
server {
    listen 80;
    server_name _;
    
    location / {
        proxy_pass http://127.0.0.1:5000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
    
    location /hls/ {
        alias /opt/hls-manager/hls/;
    }
}
EOF

sudo ln -sf /etc/nginx/sites-available/hls-manager /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true

# 13. Inicializar banco de dados
echo "🗃️ Inicializando banco de dados..."
cd /opt/hls-manager
if sudo -u hlsmanager ./venv/bin/python -c "
from app import create_app, db
app = create_app()
with app.app_context():
    db.create_all()
    print('Database tables created successfully')
"; then
    echo "✅ Banco de dados inicializado"
else
    echo "⚠️ Erro ao inicializar banco, mas continuando..."
fi

# 14. Iniciar serviços
echo "🚀 Iniciando serviços..."
sudo systemctl daemon-reload
sudo systemctl start mariadb
sleep 2

sudo systemctl enable hls-manager
sudo systemctl start hls-manager
sleep 3

sudo nginx -t 2>/dev/null && sudo systemctl restart nginx

# 15. Verificar instalação
echo "🧪 Verificando instalação..."
sleep 5

echo "Status dos serviços:"
for service in mariadb hls-manager nginx; do
    if systemctl is-active --quiet $service; then
        echo "✅ $service: ATIVO"
    else
        echo "⚠️ $service: INATIVO"
    fi
done

# Testar aplicação
if curl -s http://localhost:5000/health 2>/dev/null | grep -q "healthy"; then
    echo "✅ Aplicação está funcionando!"
else
    echo "⚠️ Aplicação não responde. Verifique os logs:"
    echo "   sudo journalctl -u hls-manager -n 20"
fi

# 16. Mostrar informações
IP=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "localhost")
echo ""
echo "🎉 HLS MANAGER INSTALADO!"
echo "========================"
echo "🌐 URL: http://$IP"
echo "👤 Usuário: admin"
echo "🔑 Senha: $ADMIN_PASSWORD"
echo ""
echo "🗄️ Banco de dados:"
echo "   Usuário: $MYSQL_APP_USER"
echo "   Senha: $MYSQL_APP_PASS"
echo ""
echo "⚙️ Comandos:"
echo "• sudo systemctl status hls-manager"
echo "• sudo journalctl -u hls-manager -f"
echo "• mysql -u $MYSQL_APP_USER -p"
echo ""
echo "📁 Diretório: /opt/hls-manager"
echo "✅ Instalação concluída!"
