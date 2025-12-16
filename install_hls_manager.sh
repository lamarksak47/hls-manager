#!/bin/bash
# install_hls_manager_final.sh - Script FINAL com todas correções

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
    software-properties-common curl wget git build-essential pkg-config

# 3. VERIFICAR se MariaDB já está instalado
echo "🔍 Verificando instalação do MariaDB..."
MARIADB_INSTALLED=false

if command -v mariadb &>/dev/null; then
    echo "✅ MariaDB já está instalado"
    MARIADB_INSTALLED=true
    
    # Verificar versão do Connector/C
    if mariadb_config --version 2>/dev/null; then
        CONNECTOR_VERSION=$(mariadb_config --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+')
        echo "📊 Versão do Connector/C: $CONNECTOR_VERSION"
        
        # Verificar se precisa atualizar
        REQUIRED_VERSION="3.3.1"
        if printf '%s\n' "$REQUIRED_VERSION" "$CONNECTOR_VERSION" | sort -V | head -n1 | grep -q "^$REQUIRED_VERSION$"; then
            echo "✅ Connector/C já está na versão necessária ($REQUIRED_VERSION+)"
            SKIP_CONNECTOR=true
        else
            echo "⚠️ Connector/C precisa ser atualizado ($CONNECTOR_VERSION < $REQUIRED_VERSION)"
            SKIP_CONNECTOR=false
        fi
    else
        echo "⚠️ Connector/C não encontrado, será instalado"
        SKIP_CONNECTOR=false
    fi
else
    echo "📥 MariaDB não encontrado, será instalado"
    MARIADB_INSTALLED=false
    SKIP_CONNECTOR=false
fi

# 4. INSTALAR/ATUALIZAR MariaDB Connector/C se necessário
if [ "$SKIP_CONNECTOR" = false ]; then
    echo "🔧 Instalando/Atualizando MariaDB Connector/C..."
    
    # Remover versões antigas
    sudo apt remove -y libmariadb3 libmariadb-dev mariadb-connector-c 2>/dev/null || true
    
    # Método 1: Tentar instalar via apt (nova versão)
    echo "📥 Tentando instalar via apt..."
    sudo apt-get install -y libmariadb3 libmariadb-dev 2>/dev/null || {
        echo "⚠️ Não foi possível instalar via apt, tentando método alternativo..."
        
        # Método 2: Compilar a partir do código fonte
        echo "📦 Compilando a partir do código fonte..."
        cd /tmp
        
        # Baixar código fonte do MariaDB Connector/C (versão atualizada)
        CONNECTOR_VERSION="3.3.9"
        echo "📥 Baixando MariaDB Connector/C $CONNECTOR_VERSION..."
        
        # Tentar diferentes mirrors
        MIRRORS=(
            "https://archive.mariadb.org/mariadb-connector-c-$CONNECTOR_VERSION/mariadb-connector-c-$CONNECTOR_VERSION-src.tar.gz"
            "https://downloads.mariadb.org/interstitial/mariadb-connector-c-$CONNECTOR_VERSION/mariadb-connector-c-$CONNECTOR_VERSION-src.tar.gz"
            "https://mirror.mariadb.org/mariadb-connector-c-$CONNECTOR_VERSION/mariadb-connector-c-$CONNECTOR_VERSION-src.tar.gz"
        )
        
        DOWNLOAD_SUCCESS=false
        for MIRROR in "${MIRRORS[@]}"; do
            echo "Tentando mirror: $MIRROR"
            if wget -q --timeout=30 --tries=2 "$MIRROR" -O mariadb-connector-c-src.tar.gz; then
                DOWNLOAD_SUCCESS=true
                echo "✅ Download bem-sucedido"
                break
            fi
        done
        
        if [ "$DOWNLOAD_SUCCESS" = false ]; then
            echo "❌ Não foi possível baixar o Connector/C"
            echo "📦 Usando versão alternativa (mysqlclient)..."
            sudo apt-get install -y default-libmysqlclient-dev
            USE_MYSQLCLIENT=true
        else
            # Extrair e compilar
            tar -xzf mariadb-connector-c-src.tar.gz
            cd mariadb-connector-c-*/ || cd mariadb-connector-c-src-*/
            
            mkdir build && cd build
            cmake .. -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local
            make -j$(nproc)
            sudo make install
            
            # Atualizar cache de bibliotecas
            sudo ldconfig
            USE_MYSQLCLIENT=false
        fi
    }
else
    USE_MYSQLCLIENT=false
fi

# 5. INSTALAR MariaDB Server se não estiver instalado
if [ "$MARIADB_INSTALLED" = false ]; then
    echo "🗄️ Instalando MariaDB Server..."
    sudo apt-get install -y mariadb-server mariadb-client
fi

# 6. Configurar MariaDB
echo "🔐 Configurando MariaDB..."
sudo systemctl start mariadb 2>/dev/null || true
sudo systemctl enable mariadb 2>/dev/null || true

# Verificar status do MariaDB
if ! sudo systemctl is-active --quiet mariadb; then
    echo "⚠️ MariaDB não está rodando, tentando iniciar..."
    sudo systemctl start mariadb
    sleep 3
fi

# 7. Configurar senha root (apenas se não estiver configurada)
echo "🔧 Configurando segurança do MariaDB..."
if sudo mysql -u root -e "SELECT 1" 2>/dev/null; then
    echo "🔐 Configurando senha root..."
    sudo mysql -u root <<-EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY 'MariaDBRootPass@2024';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
EOF
    ROOT_PASS="MariaDBRootPass@2024"
    echo "✅ Senha root configurada"
elif sudo mysql -u root -pMariaDBRootPass@2024 -e "SELECT 1" 2>/dev/null; then
    ROOT_PASS="MariaDBRootPass@2024"
    echo "✅ Usando senha root existente"
else
    echo "⚠️ MariaDB já tem senha diferente. Solicitando senha..."
    echo ""
    echo "================================================"
    echo "ATENÇÃO: MariaDB já foi configurado anteriormente."
    echo "Por favor, digite a senha do usuário root do MariaDB"
    echo "ou pressione Enter para usar a senha padrão do script:"
    echo "================================================"
    read -s USER_ROOT_PASS
    
    if [ -z "$USER_ROOT_PASS" ]; then
        ROOT_PASS="MariaDBRootPass@2024"
        echo "Usando senha padrão do script"
    else
        ROOT_PASS="$USER_ROOT_PASS"
        echo "Usando senha fornecida"
    fi
    
    # Testar a senha
    if ! sudo mysql -u root -p"$ROOT_PASS" -e "SELECT 1" 2>/dev/null; then
        echo "❌ Senha incorreta! Execute:"
        echo "   sudo mysql_secure_installation"
        echo "   ou"
        echo "   sudo systemctl restart mariadb"
        exit 1
    fi
fi

# 8. Criar banco de dados da aplicação
echo "🗃️ Criando banco de dados da aplicação..."
MYSQL_APP_PASS="HlsAppSecure@2024$(date +%s | tail -c 4)"
MYSQL_APP_USER="hls_manager"

# Tentar com a senha root configurada
if sudo mysql -u root -p"$ROOT_PASS" -e "SELECT 1" 2>/dev/null; then
    echo "Criando banco com autenticação root..."
    sudo mysql -u root -p"$ROOT_PASS" <<-EOF
DROP DATABASE IF EXISTS hls_manager;
CREATE DATABASE hls_manager CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
DROP USER IF EXISTS '${MYSQL_APP_USER}'@'localhost';
CREATE USER '${MYSQL_APP_USER}'@'localhost' IDENTIFIED BY '${MYSQL_APP_PASS}';
GRANT ALL PRIVILEGES ON hls_manager.* TO '${MYSQL_APP_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF
else
    # Tentar sem senha (caso a autenticação UNIX socket esteja habilitada)
    echo "Tentando criar banco sem autenticação..."
    sudo mysql -u root <<-EOF
DROP DATABASE IF EXISTS hls_manager;
CREATE DATABASE hls_manager CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
DROP USER IF EXISTS '${MYSQL_APP_USER}'@'localhost';
CREATE USER '${MYSQL_APP_USER}'@'localhost' IDENTIFIED BY '${MYSQL_APP_PASS}';
GRANT ALL PRIVILEGES ON hls_manager.* TO '${MYSQL_APP_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF
fi

# Verificar se o banco foi criado
if sudo mysql -u "$MYSQL_APP_USER" -p"$MYSQL_APP_PASS" -e "USE hls_manager; SELECT 'OK'" 2>/dev/null; then
    echo "✅ Banco de dados criado com sucesso!"
    echo "   Usuário: $MYSQL_APP_USER"
    echo "   Senha: $MYSQL_APP_PASS"
else
    echo "❌ Erro ao criar banco. Criando manualmente..."
    # Criar manualmente se necessário
    sudo mysql -u root -p"$ROOT_PASS" <<-MYSQL
CREATE DATABASE IF NOT EXISTS hls_manager;
CREATE USER IF NOT EXISTS '$MYSQL_APP_USER'@'localhost' IDENTIFIED BY '$MYSQL_APP_PASS';
GRANT ALL PRIVILEGES ON hls_manager.* TO '$MYSQL_APP_USER'@'localhost';
FLUSH PRIVILEGES;
MYSQL
fi

# 9. Criar usuário e diretórios do sistema
echo "👤 Criando estrutura do sistema..."
if ! id "hlsmanager" &>/dev/null; then
    sudo useradd -r -s /bin/false -m -d /opt/hls-manager hlsmanager
    echo "✅ Usuário hlsmanager criado"
else
    echo "✅ Usuário hlsmanager já existe"
fi

# Criar diretórios
sudo mkdir -p /opt/hls-manager/{uploads,hls,logs,temp,config,backups,static,media,scripts}
cd /opt/hls-manager

# Configurar permissões
sudo chown -R hlsmanager:hlsmanager /opt/hls-manager
find /opt/hls-manager -type d -exec sudo chmod 750 {} \;
sudo chmod 770 /opt/hls-manager/uploads /opt/hls-manager/temp
sudo chmod 755 /opt/hls-manager/hls /opt/hls-manager/static /opt/hls-manager/media

# 10. Configurar ambiente Python
echo "🐍 Configurando ambiente Python..."
sudo -u hlsmanager python3 -m venv venv

echo "📦 Instalando pacotes Python..."
# Instalar pip e setuptools primeiro
sudo -u hlsmanager ./venv/bin/pip install --upgrade pip setuptools wheel

# DECIDIR qual driver MySQL usar
if [ "$USE_MYSQLCLIENT" = true ]; then
    echo "Usando mysqlclient como driver MySQL..."
    sudo -u hlsmanager ./venv/bin/pip install mysqlclient
    DRIVER="mysqlclient"
else
    echo "Tentando instalar mariadb como driver..."
    if sudo -u hlsmanager ./venv/bin/pip install mariadb 2>/dev/null; then
        echo "✅ mariadb instalado com sucesso"
        DRIVER="mariadb"
    else
        echo "⚠️ Falha ao instalar mariadb, usando mysqlclient..."
        sudo apt-get install -y default-libmysqlclient-dev
        sudo -u hlsmanager ./venv/bin/pip install mysqlclient
        DRIVER="mysqlclient"
    fi
fi

# Instalar outras dependências
sudo -u hlsmanager ./venv/bin/pip install flask flask-login flask-sqlalchemy \
    flask-migrate flask-wtf flask-cors python-dotenv gunicorn cryptography \
    werkzeug pillow bcrypt flask-limiter python-dateutil

# Instalar python-magic baseado no sistema
if [ -f /etc/debian_version ]; then
    sudo apt-get install -y python3-magic
    sudo -u hlsmanager ./venv/bin/pip install python-magic-bin
else
    sudo -u hlsmanager ./venv/bin/pip install python-magic
fi

# 11. Criar configuração .env
echo "⚙️ Criando configuração..."
ADMIN_PASSWORD="Admin@$(date +%s | tail -c 6)"
SECRET_KEY=$(openssl rand -hex 32)

# Determinar a string de conexão baseada no driver
if [ "$DRIVER" = "mariadb" ]; then
    SQLALCHEMY_URI="mysql+mariadb://${MYSQL_APP_USER}:${MYSQL_APP_PASS}@localhost/hls_manager"
else
    SQLALCHEMY_URI="mysql+mysqldb://${MYSQL_APP_USER}:${MYSQL_APP_PASS}@localhost/hls_manager"
fi

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
SQLALCHEMY_DATABASE_URI=${SQLALCHEMY_URI}
SQLALCHEMY_TRACK_MODIFICATIONS=False

# Uploads
MAX_UPLOAD_SIZE=2147483648  # 2GB
MAX_CONCURRENT_JOBS=3
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

# 12. Criar aplicação Flask mínima
echo "💻 Criando aplicação Flask..."

# Criar estrutura de diretórios
sudo -u hlsmanager mkdir -p /opt/hls-manager/app/{templates,static}

# __init__.py
sudo tee /opt/hls-manager/app/__init__.py > /dev/null << 'EOF'
import os
from flask import Flask, render_template_string, jsonify
from flask_sqlalchemy import SQLAlchemy
from flask_login import LoginManager
from flask_migrate import Migrate
from flask_wtf.csrf import CSRFProtect
from dotenv import load_dotenv

# Carregar configurações
load_dotenv('/opt/hls-manager/config/.env')

db = SQLAlchemy()
login_manager = LoginManager()
migrate = Migrate()
csrf = CSRFProtect()

def create_app():
    app = Flask(__name__)
    
    # Configurações
    app.config['SECRET_KEY'] = os.getenv('SECRET_KEY')
    app.config['SQLALCHEMY_DATABASE_URI'] = os.getenv('SQLALCHEMY_DATABASE_URI')
    app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False
    app.config['MAX_CONTENT_LENGTH'] = int(os.getenv('MAX_UPLOAD_SIZE', 2147483648))
    
    # Inicializar extensões
    db.init_app(app)
    login_manager.init_app(app)
    migrate.init_app(app, db)
    csrf.init_app(app)
    
    # Configurar login manager
    login_manager.login_view = 'auth.login'
    login_manager.login_message = 'Por favor, faça login.'
    
    # Registrar blueprints (serão criados depois)
    try:
        from app.routes import main, auth, api
        app.register_blueprint(main.bp)
        app.register_blueprint(auth.bp)
        app.register_blueprint(api.bp)
        print("✅ Blueprints registrados")
    except ImportError:
        print("⚠️ Blueprints não disponíveis ainda")
    
    # Rota básica
    @app.route('/')
    def index():
        html = '''
        <!DOCTYPE html>
        <html>
        <head>
            <title>HLS Manager</title>
            <style>
                body { font-family: Arial, sans-serif; margin: 40px; }
                .container { max-width: 800px; margin: 0 auto; }
                .success { color: green; }
                .info { color: blue; }
            </style>
        </head>
        <body>
            <div class="container">
                <h1>🎬 HLS Manager</h1>
                <p class="success">✅ Sistema instalado com sucesso!</p>
                <p>Versão: 2.0.0</p>
                <p><a href="/login">Login</a> | <a href="/health">Health Check</a></p>
            </div>
        </body>
        </html>
        '''
        return render_template_string(html)
    
    @app.route('/health')
    def health():
        try:
            # Testar conexão com banco
            db.session.execute('SELECT 1')
            db_status = 'healthy'
        except:
            db_status = 'unhealthy'
        
        return jsonify({
            'status': 'ok',
            'database': db_status,
            'service': 'hls-manager'
        })
    
    return app
EOF

# models.py
sudo tee /opt/hls-manager/app/models.py > /dev/null << 'EOF'
from datetime import datetime
from flask_login import UserMixin
from werkzeug.security import generate_password_hash, check_password_hash
from app import db

class User(UserMixin, db.Model):
    __tablename__ = 'users'
    
    id = db.Column(db.Integer, primary_key=True)
    username = db.Column(db.String(80), unique=True, nullable=False)
    email = db.Column(db.String(120), unique=True, nullable=False)
    password_hash = db.Column(db.String(200))
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
    user_id = db.Column(db.Integer)
    
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

# routes/__init__.py (estrutura básica)
sudo -u hlsmanager mkdir -p /opt/hls-manager/app/routes
sudo tee /opt/hls-manager/app/routes/__init__.py > /dev/null << 'EOF'
# Blueprints serão criados aqui
EOF

# run.py
sudo tee /opt/hls-manager/run.py > /dev/null << 'EOF'
#!/usr/bin/env python3
from app import create_app, db
from app.models import User
import os

app = create_app()

@app.before_first_request
def initialize():
    with app.app_context():
        # Criar tabelas
        db.create_all()
        
        # Criar usuário admin se não existir
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
            print("✅ Usuário admin criado")
        else:
            print("✅ Usuário admin já existe")

if __name__ == '__main__':
    print(f"🚀 Iniciando HLS Manager na porta {os.getenv('PORT', 5000)}")
    app.run(
        host=os.getenv('HOST', '127.0.0.1'),
        port=int(os.getenv('PORT', 5000)),
        debug=os.getenv('DEBUG', 'False').lower() == 'true'
    )
EOF

sudo chmod +x /opt/hls-manager/run.py

# 13. Criar serviço systemd
echo "⚙️ Criando serviço systemd..."
sudo tee /etc/systemd/system/hls-manager.service > /dev/null << EOF
[Unit]
Description=HLS Manager
After=network.target mariadb.service
Requires=mariadb.service

[Service]
Type=simple
User=hlsmanager
Group=hlsmanager
WorkingDirectory=/opt/hls-manager
Environment="PATH=/opt/hls-manager/venv/bin"
Environment="PYTHONPATH=/opt/hls-manager"
ExecStart=/opt/hls-manager/venv/bin/gunicorn \
    --bind 127.0.0.1:5000 \
    --workers 2 \
    --threads 2 \
    --timeout 120 \
    --access-logfile /opt/hls-manager/logs/access.log \
    --error-logfile /opt/hls-manager/logs/error.log \
    run:app
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# 14. Configurar Nginx
echo "🌐 Configurando Nginx..."
sudo tee /etc/nginx/sites-available/hls-manager > /dev/null << 'EOF'
server {
    listen 80;
    server_name _;
    
    # Tamanho máximo de upload
    client_max_body_size 2G;
    
    # Proxy para aplicação Flask
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
    
    # Servir arquivos HLS diretamente
    location /hls/ {
        alias /opt/hls-manager/hls/;
        
        # CORS para streaming
        add_header Access-Control-Allow-Origin *;
        add_header Access-Control-Allow-Methods 'GET, OPTIONS';
        add_header Access-Control-Allow-Headers 'Range';
        
        # Cache para arquivos .ts
        location ~ \.ts$ {
            expires 365d;
            add_header Cache-Control "public, immutable";
        }
        
        # No cache para .m3u8
        location ~ \.m3u8$ {
            expires -1;
            add_header Cache-Control "no-cache";
        }
        
        autoindex off;
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

# 15. Configurar firewall
echo "🔥 Configurando firewall..."
sudo ufw allow 22/tcp 2>/dev/null || true
sudo ufw allow 80/tcp 2>/dev/null || true
sudo ufw allow 443/tcp 2>/dev/null || true
sudo ufw --force enable 2>/dev/null || true
sudo ufw reload 2>/dev/null || true

# 16. Inicializar banco de dados
echo "🗃️ Inicializando banco de dados..."
cd /opt/hls-manager
sudo -u hlsmanager ./venv/bin/python -c "
from app import create_app, db
app = create_app()
with app.app_context():
    db.create_all()
    print('✅ Tabelas do banco criadas')
    
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
        print('✅ Usuário admin criado')
    else:
        print('✅ Usuário admin já existe')
"

# 17. Iniciar serviços
echo "🚀 Iniciando serviços..."
sudo systemctl daemon-reload
sudo systemctl enable hls-manager 2>/dev/null || true
sudo systemctl enable mariadb 2>/dev/null || true
sudo systemctl enable nginx 2>/dev/null || true

sudo systemctl restart mariadb
sudo systemctl start hls-manager
sleep 3

sudo nginx -t && sudo systemctl restart nginx

# 18. Testar instalação
echo "🧪 Testando instalação..."
sleep 5

echo "Verificando serviços..."
SERVICES=("mariadb" "hls-manager" "nginx")
for SERVICE in "${SERVICES[@]}"; do
    if sudo systemctl is-active --quiet "$SERVICE"; then
        echo "✅ $SERVICE está rodando"
    else
        echo "⚠️ $SERVICE não está rodando"
        echo "   Tentando iniciar: sudo systemctl start $SERVICE"
        sudo systemctl start "$SERVICE"
    fi
done

# Testar endpoint de saúde
echo "Testando aplicação..."
if curl -s http://localhost:5000/health 2>/dev/null | grep -q "ok"; then
    echo "✅ Aplicação está respondendo"
else
    echo "⚠️ Aplicação não responde. Verificando logs..."
    sudo journalctl -u hls-manager -n 20 --no-pager 2>/dev/null || true
fi

# 19. Mostrar informações finais
IP=$(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}' 2>/dev/null || echo "SEU_IP")
echo ""
echo "🎉 HLS MANAGER INSTALADO COM SUCESSO!"
echo "================================================"
echo "🌐 URL DO SISTEMA: http://$IP"
echo "👤 USUÁRIO ADMIN: admin"
echo "🔑 SENHA ADMIN: $ADMIN_PASSWORD"
echo "================================================"
echo ""
echo "🗄️ INFORMAÇÕES DO BANCO:"
echo "• Driver: $DRIVER"
echo "• Usuário: $MYSQL_APP_USER"
echo "• Senha: $MYSQL_APP_PASS"
echo "• Banco: hls_manager"
echo ""
echo "⚙️ COMANDOS ÚTEIS:"
echo "• Status: sudo systemctl status hls-manager"
echo "• Logs: sudo journalctl -u hls-manager -f"
echo "• Reiniciar: sudo systemctl restart hls-manager"
echo "• Banco: mysql -u $MYSQL_APP_USER -p"
echo ""
echo "📁 ESTRUTURA: /opt/hls-manager/"
echo "🎬 Pronto para usar! Acesse http://$IP"
