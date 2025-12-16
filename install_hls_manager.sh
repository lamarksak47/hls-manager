#!/bin/bash
# install_hls_manager_fixed.sh - Script CORRIGIDO com MariaDB funcional

set -e  # Sai imediatamente em caso de erro

echo "🎬 INSTALANDO HLS MANAGER COMPLETO (VERSÃO CORRIGIDA)"
echo "📊 Sistema com painel de gerenciamento + MariaDB"

# 1. Atualizar sistema
echo "📦 Atualizando sistema..."
sudo apt-get update
sudo apt-get upgrade -y

# 2. Instalar dependências (INCLUINDO expect)
echo "📦 Instalando dependências..."
sudo apt-get install -y python3 python3-pip ffmpeg python3-venv libmagic1 nginx ufw mariadb-server mariadb-client libmariadb-dev python3-dev expect

# 3. Configurar MariaDB (MÉTODO CORRIGIDO)
echo "🗄️ Configurando MariaDB..."
sudo systemctl start mariadb
sudo systemctl enable mariadb

# VERIFICAR se o MariaDB já tem senha root configurada
echo "🔍 Verificando estado do MariaDB..."

# Tentar conectar sem senha primeiro
if sudo mysql -u root -e "SELECT 1" 2>/dev/null; then
    echo "✅ MariaDB acessível sem senha. Configurando segurança..."
    
    # Método 1: Usar expect apenas se não houver senha
    SECURE_MYSQL=$(expect -c "
set timeout 10
spawn sudo mysql_secure_installation
expect \"Enter current password for root (enter for none):\"
send \"\r\"
expect \"Switch to unix_socket authentication\"
send \"n\r\"
expect \"Change the root password?\"
send \"y\r\"
expect \"New password:\"
send \"MariaDBRootPass@2024\r\"
expect \"Re-enter new password:\"
send \"MariaDBRootPass@2024\r\"
expect \"Remove anonymous users?\"
send \"y\r\"
expect \"Disallow root login remotely?\"
send \"y\r\"
expect \"Remove test database and access to it?\"
send \"y\r\"
expect \"Reload privilege tables now?\"
send \"y\r\"
expect eof
")
    
    echo "$SECURE_MYSQL"
    ROOT_PASS="MariaDBRootPass@2024"
    
elif sudo mysql -u root -pMariaDBRootPass@2024 -e "SELECT 1" 2>/dev/null; then
    echo "✅ Senha padrão já configurada. Usando senha existente..."
    ROOT_PASS="MariaDBRootPass@2024"
    
else
    echo "⚠️ MariaDB já tem senha diferente. Pedindo senha do root..."
    echo ""
    echo "================================================"
    echo "ATENÇÃO: O MariaDB já foi configurado anteriormente."
    echo "Por favor, digite a senha do usuário root do MariaDB:"
    echo "================================================"
    read -s ROOT_PASS
    
    # Testar a senha fornecida
    if ! sudo mysql -u root -p"$ROOT_PASS" -e "SELECT 1" 2>/dev/null; then
        echo "❌ Senha incorreta! Execute os comandos de recuperação:"
        echo ""
        echo "Para redefinir a senha do MariaDB:"
        echo "1. sudo systemctl stop mariadb"
        echo "2. sudo mysqld_safe --skip-grant-tables --skip-networking &"
        echo "3. sudo mysql"
        echo "4. No MariaDB, execute:"
        echo "   FLUSH PRIVILEGES;"
        echo "   ALTER USER 'root'@'localhost' IDENTIFIED BY 'NovaSenha';"
        echo "   FLUSH PRIVILEGES;"
        echo "   EXIT;"
        echo "5. sudo pkill -f mysqld_safe"
        echo "6. sudo systemctl start mariadb"
        echo ""
        exit 1
    fi
fi

# 4. Criar banco de dados e usuário (MÉTODO ATUALIZADO)
echo "🗃️ Criando banco de dados e usuário da aplicação..."
MYSQL_APP_PASS="HlsAppSecure@2024$(date +%s | tail -c 4)"
MYSQL_APP_USER="hls_manager"

# Comando para criar banco e usuário
SQL_COMMANDS="
DROP DATABASE IF EXISTS hls_manager;
CREATE DATABASE hls_manager CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
DROP USER IF EXISTS '${MYSQL_APP_USER}'@'localhost';
CREATE USER '${MYSQL_APP_USER}'@'localhost' IDENTIFIED BY '${MYSQL_APP_PASS}';
GRANT ALL PRIVILEGES ON hls_manager.* TO '${MYSQL_APP_USER}'@'localhost';
FLUSH PRIVILEGES;
"

# Executar comandos SQL
echo "Executando: sudo mysql -u root -p'********' -e \"\$SQL_COMMANDS\""
sudo mysql -u root -p"$ROOT_PASS" -e "$SQL_COMMANDS"

if [ $? -eq 0 ]; then
    echo "✅ Banco de dados e usuário criados com sucesso!"
    echo "📋 Credenciais do banco:"
    echo "   Usuário: ${MYSQL_APP_USER}"
    echo "   Senha: ${MYSQL_APP_PASS}"
    echo "   Banco: hls_manager"
else
    echo "❌ Erro ao criar banco de dados!"
    echo "Tentando método alternativo..."
    
    # Método alternativo: conectar via socket
    sudo mysql -u root <<-EOF
DROP DATABASE IF EXISTS hls_manager;
CREATE DATABASE hls_manager CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
DROP USER IF EXISTS '${MYSQL_APP_USER}'@'localhost';
CREATE USER '${MYSQL_APP_USER}'@'localhost' IDENTIFIED BY '${MYSQL_APP_PASS}';
GRANT ALL PRIVILEGES ON hls_manager.* TO '${MYSQL_APP_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF
    
    if [ $? -eq 0 ]; then
        echo "✅ Banco criado via método alternativo!"
    else
        echo "❌ Falha crítica na configuração do banco."
        echo "Configure manualmente com:"
        echo "sudo mysql -u root -p"
        echo "# No MariaDB, execute:"
        echo "CREATE DATABASE hls_manager;"
        echo "CREATE USER 'hls_manager'@'localhost' IDENTIFIED BY '${MYSQL_APP_PASS}';"
        echo "GRANT ALL PRIVILEGES ON hls_manager.* TO 'hls_manager'@'localhost';"
        echo "FLUSH PRIVILEGES;"
        exit 1
    fi
fi

# 5. Criar usuário dedicado do sistema
echo "👤 Criando usuário dedicado..."
if ! id "hlsmanager" &>/dev/null; then
    sudo useradd -r -s /bin/false -m -d /opt/hls-manager hlsmanager
    echo "✅ Usuário hlsmanager criado"
else
    echo "✅ Usuário hlsmanager já existe"
fi

# 6. Criar diretórios com estrutura completa
echo "📁 Criando estrutura de diretórios..."
sudo mkdir -p /opt/hls-manager/{uploads,hls,logs,temp,config,backups,static,media,scripts}
cd /opt/hls-manager

# 7. Configurar permissões
echo "🔐 Configurando permissões..."
sudo chown -R hlsmanager:hlsmanager /opt/hls-manager
sudo chmod 750 /opt/hls-manager
sudo chmod 770 /opt/hls-manager/uploads
sudo chmod 770 /opt/hls-manager/temp
sudo chmod 755 /opt/hls-manager/hls
sudo chmod 755 /opt/hls-manager/static
sudo chmod 755 /opt/hls-manager/media
sudo chmod 750 /opt/hls-manager/logs
sudo chmod 750 /opt/hls-manager/config
sudo chmod 750 /opt/hls-manager/backups
sudo chmod 750 /opt/hls-manager/scripts

# 8. Criar virtualenv
echo "🐍 Criando ambiente virtual..."
sudo -u hlsmanager python3 -m venv venv
sudo -u hlsmanager ./venv/bin/pip install --upgrade pip

# 9. Instalar dependências Python
echo "📦 Instalando dependências Python..."
sudo -u hlsmanager ./venv/bin/pip install flask flask-login flask-sqlalchemy flask-migrate flask-wtf flask-cors \
    mariadb python-magic python-dotenv gunicorn cryptography werkzeug \
    pillow bcrypt flask-limiter python-dateutil

# 10. Criar arquivo de configuração .env com senhas reais
echo "⚙️ Criando configuração..."
ADMIN_PASSWORD="AdminPass@2024$(date +%s | tail -c 4)"
SECRET_KEY=$(openssl rand -hex 32)

sudo tee /opt/hls-manager/config/.env > /dev/null << EOF
# Configurações do HLS Manager
DEBUG=False
PORT=5000
HOST=127.0.0.1
SECRET_KEY=${SECRET_KEY}

# Banco de Dados
DB_HOST=localhost
DB_PORT=3306
DB_NAME=hls_manager
DB_USER=${MYSQL_APP_USER}
DB_PASSWORD=${MYSQL_APP_PASS}
SQLALCHEMY_DATABASE_URI=mysql+pymysql://${MYSQL_APP_USER}:${MYSQL_APP_PASS}@localhost/hls_manager

# Uploads
MAX_UPLOAD_SIZE=2147483648  # 2GB
MAX_CONCURRENT_JOBS=5
HLS_SEGMENT_TIME=10
HLS_DELETE_AFTER_DAYS=30
ALLOWED_EXTENSIONS=mp4,mkv,avi,mov,webm,mpeg,mpg,flv

# Autenticação
ADMIN_USERNAME=admin
ADMIN_EMAIL=admin@localhost
ADMIN_PASSWORD=${ADMIN_PASSWORD}

# Segurança
SESSION_TIMEOUT=7200
ENABLE_RATE_LIMIT=True
MAX_REQUESTS_PER_MINUTE=100
LOGIN_ATTEMPTS_LIMIT=5

# Caminhos
BASE_DIR=/opt/hls-manager
UPLOAD_FOLDER=/opt/hls-manager/uploads
HLS_FOLDER=/opt/hls-manager/hls
TEMP_FOLDER=/opt/hls-manager/temp
LOG_FOLDER=/opt/hls-manager/logs
STATIC_FOLDER=/opt/hls-manager/static
MEDIA_FOLDER=/opt/hls-manager/media
EOF

sudo chown hlsmanager:hlsmanager /opt/hls-manager/config/.env
sudo chmod 640 /opt/hls-manager/config/.env

# 11. Criar estrutura da aplicação
echo "💻 Criando estrutura da aplicação..."
sudo -u hlsmanager mkdir -p /opt/hls-manager/app/{models,routes,templates,forms,utils,static/css,static/js,static/images}

# 12. Criar arquivo __init__.py principal
sudo tee /opt/hls-manager/app/__init__.py > /dev/null << 'EOF'
import os
import logging
from datetime import datetime
from pathlib import Path

from flask import Flask, render_template, request, flash, redirect, url_for
from flask_sqlalchemy import SQLAlchemy
from flask_login import LoginManager, current_user
from flask_migrate import Migrate
from flask_wtf.csrf import CSRFProtect
from flask_limiter import Limiter
from flask_limiter.util import get_remote_address
from dotenv import load_dotenv

# Carregar configurações
config_path = '/opt/hls-manager/config/.env'
if os.path.exists(config_path):
    load_dotenv(config_path)

# Inicializar extensões
db = SQLAlchemy()
login_manager = LoginManager()
migrate = Migrate()
csrf = CSRFProtect()
limiter = Limiter(key_func=get_remote_address)

def create_app():
    """Factory function para criar a aplicação Flask"""
    app = Flask(__name__)
    
    # Configurações
    app.config['SECRET_KEY'] = os.getenv('SECRET_KEY', 'dev-secret-key')
    app.config['SQLALCHEMY_DATABASE_URI'] = os.getenv('SQLALCHEMY_DATABASE_URI')
    app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False
    app.config['MAX_CONTENT_LENGTH'] = int(os.getenv('MAX_UPLOAD_SIZE', 2147483648))
    app.config['SESSION_COOKIE_SECURE'] = os.getenv('DEBUG', 'False').lower() != 'true'
    app.config['SESSION_COOKIE_HTTPONLY'] = True
    app.config['SESSION_COOKIE_SAMESITE'] = 'Strict'
    
    # Inicializar extensões
    db.init_app(app)
    login_manager.init_app(app)
    migrate.init_app(app, db)
    csrf.init_app(app)
    limiter.init_app(app)
    
    # Configurar login manager
    login_manager.login_view = 'auth.login'
    login_manager.login_message = 'Por favor, faça login para acessar esta página.'
    login_manager.login_message_category = 'warning'
    
    # Registrar blueprints (serão criados posteriormente)
    try:
        from app.routes import main, auth, channels, api
        app.register_blueprint(main.bp)
        app.register_blueprint(auth.bp)
        app.register_blueprint(channels.bp)
        app.register_blueprint(api.bp)
    except ImportError:
        print("⚠️ Blueprints ainda não criados. Execute o script novamente após completar.")
    
    # Filtros de template
    @app.template_filter('format_datetime')
    def format_datetime_filter(value):
        if isinstance(value, datetime):
            return value.strftime('%d/%m/%Y %H:%M:%S')
        return value
    
    @app.template_filter('format_size')
    def format_size_filter(value):
        for unit in ['B', 'KB', 'MB', 'GB']:
            if value < 1024.0:
                return f"{value:.2f} {unit}"
            value /= 1024.0
        return f"{value:.2f} TB"
    
    # Context processor
    @app.context_processor
    def inject_globals():
        return {
            'current_year': datetime.now().year,
            'app_name': 'HLS Manager'
        }
    
    # Error handlers
    @app.errorhandler(404)
    def not_found(error):
        if request.headers.get('X-Requested-With') == 'XMLHttpRequest':
            return {'error': 'Recurso não encontrado'}, 404
        return render_template('errors/404.html'), 404
    
    @app.errorhandler(500)
    def internal_error(error):
        app.logger.error(f'Erro interno: {error}')
        if request.headers.get('X-Requested-With') == 'XMLHttpRequest':
            return {'error': 'Erro interno do servidor'}, 500
        return render_template('errors/500.html'), 500
    
    # Configurar logging
    if not app.debug:
        log_dir = Path('/opt/hls-manager/logs')
        log_dir.mkdir(exist_ok=True)
        
        file_handler = logging.handlers.RotatingFileHandler(
            log_dir / 'hls-manager.log',
            maxBytes=10485760,  # 10MB
            backupCount=10
        )
        file_handler.setFormatter(logging.Formatter(
            '%(asctime)s %(levelname)s: %(message)s [in %(pathname)s:%(lineno)d]'
        ))
        file_handler.setLevel(logging.INFO)
        app.logger.addHandler(file_handler)
        app.logger.setLevel(logging.INFO)
    
    return app
EOF

# 13. Criar arquivo run.py simplificado
sudo tee /opt/hls-manager/run.py > /dev/null << 'EOF'
#!/usr/bin/env python3
"""
Ponto de entrada principal da aplicação HLS Manager
"""
import os
import sys
from pathlib import Path

# Adicionar diretório app ao path
app_dir = Path(__file__).parent / 'app'
sys.path.insert(0, str(app_dir))

from app import create_app, db

app = create_app()

if __name__ == '__main__':
    print(f"🚀 Iniciando HLS Manager na porta {app.config.get('PORT', 5000)}")
    app.run(
        host=app.config.get('HOST', '127.0.0.1'),
        port=app.config.get('PORT', 5000),
        debug=app.config.get('DEBUG', False)
    )
EOF

sudo chmod +x /opt/hls-manager/run.py

# 14. Criar arquivos de modelos básicos
sudo tee /opt/hls-manager/app/models/__init__.py > /dev/null << 'EOF'
from datetime import datetime
from flask_login import UserMixin
from werkzeug.security import generate_password_hash, check_password_hash
from app import db

class User(UserMixin, db.Model):
    __tablename__ = 'users'
    
    id = db.Column(db.Integer, primary_key=True)
    username = db.Column(db.String(64), unique=True, nullable=False)
    email = db.Column(db.String(120), unique=True, nullable=False)
    password_hash = db.Column(db.String(256), nullable=False)
    is_active = db.Column(db.Boolean, default=True)
    is_admin = db.Column(db.Boolean, default=False)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    last_login = db.Column(db.DateTime)
    
    def set_password(self, password):
        self.password_hash = generate_password_hash(password)
    
    def check_password(self, password):
        return check_password_hash(self.password_hash, password)
    
    def __repr__(self):
        return f'<User {self.username}>'

class Channel(db.Model):
    __tablename__ = 'channels'
    
    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(128), nullable=False)
    slug = db.Column(db.String(128), unique=True, nullable=False)
    description = db.Column(db.Text)
    status = db.Column(db.String(20), default='draft')
    hls_path = db.Column(db.String(512))
    user_id = db.Column(db.Integer, db.ForeignKey('users.id'), nullable=False)
    
    duration = db.Column(db.Integer)
    resolution = db.Column(db.String(32))
    file_size = db.Column(db.BigInteger)
    segment_count = db.Column(db.Integer)
    bitrate = db.Column(db.Integer)
    
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    updated_at = db.Column(db.DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)
    
    def __repr__(self):
        return f'<Channel {self.name}>'
EOF

# 15. Criar serviço systemd
echo "⚙️ Criando serviço systemd..."
sudo tee /etc/systemd/system/hls-manager.service > /dev/null << EOF
[Unit]
Description=HLS Manager Service
After=network.target mariadb.service
Requires=mariadb.service

[Service]
Type=simple
User=hlsmanager
Group=hlsmanager
WorkingDirectory=/opt/hls-manager
Environment=PATH=/opt/hls-manager/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=PYTHONPATH=/opt/hls-manager
Environment=PYTHONUNBUFFERED=1

# Configurações de segurança
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=/opt/hls-manager/uploads /opt/hls-manager/hls /opt/hls-manager/logs /opt/hls-manager/temp
ProtectHome=true
RestrictRealtime=true

# Execução
ExecStart=/opt/hls-manager/venv/bin/gunicorn \
  --bind 127.0.0.1:5000 \
  --workers 2 \
  --threads 2 \
  --timeout 120 \
  --access-logfile /opt/hls-manager/logs/gunicorn-access.log \
  --error-logfile /opt/hls-manager/logs/gunicorn-error.log \
  run:app

# Reinício automático
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# 16. Configurar Nginx
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
        proxy_set_header X-Forwarded-Proto $scheme;
        
        proxy_connect_timeout 60s;
        proxy_send_timeout 300s;
        proxy_read_timeout 300s;
    }
    
    location /hls/ {
        alias /opt/hls-manager/hls/;
        
        location ~ \.ts$ {
            expires 365d;
            add_header Cache-Control "public, immutable";
        }
        
        location ~ \.m3u8$ {
            expires -1;
            add_header Cache-Control "no-cache, no-store, must-revalidate";
        }
        
        autoindex off;
    }
    
    location ~ ^/(uploads|temp|config|logs|backups) {
        deny all;
        return 403;
    }
}
EOF

sudo ln -sf /etc/nginx/sites-available/hls-manager /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default 2>/dev/null

# 17. Configurar firewall
echo "🔥 Configurando firewall..."
sudo ufw --force enable 2>/dev/null || true
sudo ufw allow 22/tcp 2>/dev/null || true
sudo ufw allow 80/tcp 2>/dev/null || true
sudo ufw --force reload 2>/dev/null || true

# 18. Inicializar banco de dados
echo "🗃️ Inicializando banco de dados..."
cd /opt/hls-manager
sudo -u hlsmanager ./venv/bin/python -c "
from app import create_app, db
app = create_app()
with app.app_context():
    db.create_all()
    print('✅ Tabelas do banco criadas com sucesso!')
    
    # Criar usuário admin
    from app.models import User
    import os
    
    admin = User.query.filter_by(username='admin').first()
    if not admin:
        admin = User(
            username='admin',
            email='admin@localhost',
            is_admin=True,
            is_active=True
        )
        admin.set_password(os.getenv('ADMIN_PASSWORD'))
        db.session.add(admin)
        db.session.commit()
        print('✅ Usuário admin criado com sucesso!')
    else:
        print('✅ Usuário admin já existe')
"

# 19. Iniciar serviços
echo "🚀 Iniciando serviços..."
sudo systemctl daemon-reload
sudo systemctl enable hls-manager
sudo systemctl start hls-manager
sudo systemctl enable nginx
sudo nginx -t && sudo systemctl restart nginx

# 20. Criar script de inicialização rápida
sudo tee /opt/hls-manager/start.sh > /dev/null << 'EOF'
#!/bin/bash
echo "Iniciando HLS Manager..."
sudo systemctl start mariadb
sudo systemctl start hls-manager
sudo systemctl start nginx
echo "✅ Serviços iniciados!"
echo ""
echo "Para verificar status: sudo systemctl status hls-manager"
echo "Para ver logs: sudo journalctl -u hls-manager -f"
EOF

sudo chmod +x /opt/hls-manager/start.sh
sudo chown hlsmanager:hlsmanager /opt/hls-manager/start.sh

# 21. Testar instalação
echo "🧪 Testando instalação..."
sleep 5

# Verificar serviços
services=("hls-manager" "mariadb" "nginx")
for service in "${services[@]}"; do
    if systemctl is-active --quiet "$service"; then
        echo "✅ Serviço $service está rodando"
    else
        echo "⚠️ Serviço $service não iniciou automaticamente"
        echo "   Tente: sudo systemctl start $service"
    fi
done

# 22. Mostrar informações finais
IP=$(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}' 2>/dev/null || echo "SEU_IP")
echo ""
echo "🎉 HLS MANAGER INSTALADO COM SUCESSO!"
echo ""
echo "🔐 INFORMAÇÕES DE ACESSO CRÍTICAS:"
echo "================================================"
echo "🌐 URL DO SISTEMA: http://$IP"
echo "👤 USUÁRIO ADMIN: admin"
echo "🔑 SENHA ADMIN: $ADMIN_PASSWORD"
echo "================================================"
echo ""
echo "🗄️ INFORMAÇÕES DO BANCO DE DADOS:"
echo "• Host: localhost"
echo "• Banco: hls_manager"
echo "• Usuário: $MYSQL_APP_USER"
echo "• Senha: $MYSQL_APP_PASS"
echo ""
echo "⚙️ COMANDOS ÚTEIS:"
echo "• Iniciar tudo: /opt/hls-manager/start.sh"
echo "• Status: sudo systemctl status hls-manager"
echo "• Logs: sudo journalctl -u hls-manager -f"
echo "• Reiniciar: sudo systemctl restart hls-manager"
echo ""
echo "📁 ESTRUTURA PRINCIPAL:"
echo "/opt/hls-manager/"
echo "├── app/              # Aplicação Flask"
echo "├── uploads/          # Uploads de vídeos"
echo "├── hls/              # Arquivos HLS gerados"
echo "├── config/.env       # Configurações (SENHAS AQUI!)"
echo "└── logs/             # Logs da aplicação"
echo ""
echo "🚨 IMPORTANTE:"
echo "1. ANOTE AS SENHAS ACIMA EM UM LOCAL SEGURO!"
echo "2. Após login, ALTERE a senha do admin"
echo "3. Para uploads grandes, ajuste MAX_UPLOAD_SIZE no .env"
echo ""
echo "🎬 Pronto! Acesse http://$IP e comece a criar seus canais!"
