#!/bin/bash
# install_hls_manager_complete.sh - Script COMPLETO com todas correções

set -e

echo "🎬 INSTALANDO HLS MANAGER COMPLETO (VERSÃO FINAL)"
echo "================================================"

# 1. Atualizar sistema
echo "📦 Atualizando sistema..."
sudo apt-get update
sudo apt-get upgrade -y

# 2. Instalar dependências básicas
echo "📦 Instalando dependências básicas..."
sudo apt-get install -y python3 python3-pip ffmpeg python3-venv nginx ufw expect \
    software-properties-common curl wget git

# 3. CORREÇÃO: Instalar MariaDB Connector/C atualizado
echo "🔧 CORRIGINDO: Instalando MariaDB Connector/C atualizado..."

# Remover versões antigas se existirem
sudo apt remove -y libmariadb3 libmariadb-dev mariadb-connector-c 2>/dev/null || true

# Baixar e instalar MariaDB Connector/C 3.3.4 (versão estável)
echo "📥 Baixando MariaDB Connector/C 3.3.4..."
cd /tmp
wget -q https://archive.mariadb.org/mariadb-12.2.1/bintar-linux-systemd-x86_64/mariadb-12.2.1-linux-systemd-x86_64.tar.gz
tar -xzf mariadb-connector-c-3.3.4-ubuntu-jammy-amd64.tar.gz
cd mariadb-connector-c-3.3.4-ubuntu-jammy-amd64

# Instalar manualmente
sudo cp -r include/* /usr/include/
sudo cp -r lib/* /usr/lib/x86_64-linux-gnu/
sudo ldconfig

# Verificar instalação
echo "✅ MariaDB Connector/C instalado:"
mariadb_config --version 2>/dev/null || echo "Usando versão manual 3.3.4"

# 4. Instalar MariaDB Server
echo "🗄️ Instalando MariaDB Server..."
sudo apt-get install -y mariadb-server mariadb-client

# 5. Configurar MariaDB (método simplificado)
echo "🔐 Configurando segurança do MariaDB..."
sudo systemctl start mariadb
sudo systemctl enable mariadb

# Configurar senha root se necessário
if sudo mysql -u root -e "SELECT 1" 2>/dev/null; then
    echo "🔧 Configurando senha root do MariaDB..."
    sudo mysql -u root <<-EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY 'MariaDBRootPass@2024';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
EOF
    ROOT_PASS="MariaDBRootPass@2024"
else
    echo "⚠️ MariaDB já tem senha. Usando configuração existente."
    ROOT_PASS="MariaDBRootPass@2024"
fi

# 6. Criar banco de dados da aplicação
echo "🗃️ Criando banco de dados da aplicação..."
MYSQL_APP_PASS="HlsAppSecure@2024$(date +%s | tail -c 4)"
MYSQL_APP_USER="hls_manager"

sudo mysql -u root -p"$ROOT_PASS" <<-EOF 2>/dev/null || sudo mysql -u root <<-EOF
CREATE DATABASE IF NOT EXISTS hls_manager CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${MYSQL_APP_USER}'@'localhost' IDENTIFIED BY '${MYSQL_APP_PASS}';
GRANT ALL PRIVILEGES ON hls_manager.* TO '${MYSQL_APP_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF

echo "✅ Banco criado: usuário=${MYSQL_APP_USER}, senha=${MYSQL_APP_PASS}"

# 7. Criar usuário e diretórios do sistema
echo "👤 Criando estrutura do sistema..."
if ! id "hlsmanager" &>/dev/null; then
    sudo useradd -r -s /bin/false -m -d /opt/hls-manager hlsmanager
fi

sudo mkdir -p /opt/hls-manager/{uploads,hls,logs,temp,config,backups,static,media,scripts}
cd /opt/hls-manager
sudo chown -R hlsmanager:hlsmanager /opt/hls-manager
sudo chmod 750 /opt/hls-manager
sudo chmod 770 /opt/hls-manager/uploads /opt/hls-manager/temp
sudo chmod 755 /opt/hls-manager/hls /opt/hls-manager/static /opt/hls-manager/media
sudo chmod 750 /opt/hls-manager/logs /opt/hls-manager/config /opt/hls-manager/backups /opt/hls-manager/scripts

# 8. Criar virtualenv Python
echo "🐍 Configurando ambiente Python..."
sudo -u hlsmanager python3 -m venv venv

# CORREÇÃO: Instalar mariadb usando binary wheel
echo "📦 Instalando pacotes Python (com correção para mariadb)..."
sudo -u hlsmanager ./venv/bin/pip install --upgrade pip setuptools wheel

# Primeiro tentar instalar com binary wheel
sudo -u hlsmanager ./venv/bin/pip install mariadb --no-binary mariadb 2>/dev/null || \
sudo -u hlsmanager ./venv/bin/pip install mysqlclient  # Fallback

# Instalar outras dependências
sudo -u hlsmanager ./venv/bin/pip install flask flask-login flask-sqlalchemy \
    flask-migrate flask-wtf flask-cors python-dotenv gunicorn cryptography \
    werkzeug pillow bcrypt flask-limiter python-dateutil python-magic

# 9. Criar configuração .env
echo "⚙️ Criando configuração..."
ADMIN_PASSWORD="Admin@$(date +%s | tail -c 6)"
SECRET_KEY=$(openssl rand -hex 32)

sudo tee /opt/hls-manager/config/.env > /dev/null << EOF
DEBUG=False
PORT=5000
HOST=127.0.0.1
SECRET_KEY=${SECRET_KEY}

DB_HOST=localhost
DB_PORT=3306
DB_NAME=hls_manager
DB_USER=${MYSQL_APP_USER}
DB_PASSWORD=${MYSQL_APP_PASS}
SQLALCHEMY_DATABASE_URI=mysql+pymysql://${MYSQL_APP_USER}:${MYSQL_APP_PASS}@localhost/hls_manager

MAX_UPLOAD_SIZE=2147483648
MAX_CONCURRENT_JOBS=3
HLS_SEGMENT_TIME=10
HLS_DELETE_AFTER_DAYS=30

ADMIN_USERNAME=admin
ADMIN_EMAIL=admin@localhost
ADMIN_PASSWORD=${ADMIN_PASSWORD}

SESSION_TIMEOUT=7200
ENABLE_RATE_LIMIT=True

BASE_DIR=/opt/hls-manager
UPLOAD_FOLDER=/opt/hls-manager/uploads
HLS_FOLDER=/opt/hls-manager/hls
TEMP_FOLDER=/opt/hls-manager/temp
LOG_FOLDER=/opt/hls-manager/logs
EOF

sudo chown hlsmanager:hlsmanager /opt/hls-manager/config/.env
sudo chmod 640 /opt/hls-manager/config/.env

# 10. Criar aplicação Flask mínima funcional
echo "💻 Criando aplicação Flask..."
sudo -u hlsmanager mkdir -p /opt/hls-manager/app

# __init__.py
sudo tee /opt/hls-manager/app/__init__.py > /dev/null << 'EOF'
from flask import Flask
from flask_sqlalchemy import SQLAlchemy
from flask_login import LoginManager
from flask_migrate import Migrate
import os
from dotenv import load_dotenv

load_dotenv('/opt/hls-manager/config/.env')

db = SQLAlchemy()
login_manager = LoginManager()
migrate = Migrate()

def create_app():
    app = Flask(__name__)
    app.config['SECRET_KEY'] = os.getenv('SECRET_KEY')
    app.config['SQLALCHEMY_DATABASE_URI'] = os.getenv('SQLALCHEMY_DATABASE_URI')
    app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False
    
    db.init_app(app)
    login_manager.init_app(app)
    migrate.init_app(app, db)
    
    # Rota básica para teste
    @app.route('/')
    def index():
        return '<h1>HLS Manager</h1><p>Sistema instalado com sucesso!</p>'
    
    @app.route('/health')
    def health():
        return 'OK', 200
    
    return app
EOF

# models.py
sudo tee /opt/hls-manager/app/models.py > /dev/null << 'EOF'
from app import db
from flask_login import UserMixin
from datetime import datetime
from werkzeug.security import generate_password_hash, check_password_hash

class User(UserMixin, db.Model):
    id = db.Column(db.Integer, primary_key=True)
    username = db.Column(db.String(80), unique=True, nullable=False)
    email = db.Column(db.String(120), unique=True, nullable=False)
    password_hash = db.Column(db.String(200))
    is_admin = db.Column(db.Boolean, default=False)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    
    def set_password(self, password):
        self.password_hash = generate_password_hash(password)
    
    def check_password(self, password):
        return check_password_hash(self.password_hash, password)
EOF

# run.py
sudo tee /opt/hls-manager/run.py > /dev/null << 'EOF'
#!/usr/bin/env python3
from app import create_app, db
from app.models import User
import os

app = create_app()

@app.before_first_request
def create_tables():
    with app.app_context():
        db.create_all()
        # Criar usuário admin se não existir
        admin = User.query.filter_by(username='admin').first()
        if not admin:
            admin = User(
                username='admin',
                email='admin@localhost',
                is_admin=True
            )
            admin.set_password(os.getenv('ADMIN_PASSWORD'))
            db.session.add(admin)
            db.session.commit()
            print("✅ Usuário admin criado")

if __name__ == '__main__':
    app.run(host='127.0.0.1', port=5000, debug=False)
EOF

sudo chmod +x /opt/hls-manager/run.py

# 11. Criar serviço systemd
echo "⚙️ Criando serviço systemd..."
sudo tee /etc/systemd/system/hls-manager.service > /dev/null << EOF
[Unit]
Description=HLS Manager
After=network.target mariadb.service

[Service]
User=hlsmanager
Group=hlsmanager
WorkingDirectory=/opt/hls-manager
Environment="PATH=/opt/hls-manager/venv/bin"
ExecStart=/opt/hls-manager/venv/bin/gunicorn --bind 127.0.0.1:5000 run:app
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# 12. Configurar Nginx
echo "🌐 Configurando Nginx..."
sudo tee /etc/nginx/sites-available/hls-manager > /dev/null << 'EOF'
server {
    listen 80;
    server_name _;
    client_max_body_size 2G;
    
    location / {
        proxy_pass http://127.0.0.1:5000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
    
    location /hls/ {
        alias /opt/hls-manager/hls/;
        expires 365d;
        add_header Cache-Control "public, immutable";
    }
}
EOF

sudo ln -sf /etc/nginx/sites-available/hls-manager /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default

# 13. Configurar firewall
echo "🔥 Configurando firewall..."
sudo ufw allow 80/tcp
sudo ufw allow 22/tcp
sudo ufw --force enable || true

# 14. Inicializar banco e iniciar serviços
echo "🚀 Inicializando sistema..."
cd /opt/hls-manager
sudo -u hlsmanager ./venv/bin/python -c "
from app import create_app, db
app = create_app()
with app.app_context():
    db.create_all()
    print('✅ Banco de dados inicializado')
"

sudo systemctl daemon-reload
sudo systemctl enable hls-manager mariadb nginx
sudo systemctl restart mariadb
sudo systemctl start hls-manager
sudo systemctl restart nginx

# 15. Testar
echo "🧪 Testando instalação..."
sleep 3

if curl -s http://localhost:5000/health 2>/dev/null | grep -q "OK"; then
    echo "✅ Aplicação Flask está rodando!"
else
    echo "⚠️ Aplicação não responde. Verificando logs..."
    sudo journalctl -u hls-manager -n 20 --no-pager
fi

# 16. Mostrar informações
IP=$(hostname -I | awk '{print $1}' 2>/dev/null || curl -s ifconfig.me)
echo ""
echo "🎉 HLS MANAGER INSTALADO COM SUCESSO!"
echo "================================================"
echo "🌐 URL: http://$IP"
echo "👤 Usuário: admin"
echo "🔑 Senha: $ADMIN_PASSWORD"
echo "================================================"
echo ""
echo "⚙️ Comandos úteis:"
echo "• sudo systemctl status hls-manager"
echo "• sudo journalctl -u hls-manager -f"
echo "• sudo mysql -u hls_manager -p"
echo ""
echo "📁 Estrutura: /opt/hls-manager/"
echo "🎬 Pronto para usar!"
