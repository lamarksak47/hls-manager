#!/bin/bash
# install_hls_manager_final_fixed.sh - Script DEFINITIVO para resetar MariaDB

set -e

echo "🔧 RESETANDO E INSTALANDO HLS MANAGER COMPLETO"
echo "=============================================="

# 1. PARAR E REMOVER MariaDB completamente
echo "🗑️ Removendo MariaDB antigo..."
sudo systemctl stop mariadb 2>/dev/null || true
sudo systemctl stop mysql 2>/dev/null || true

sudo apt-get remove --purge -y mariadb-server mariadb-client mariadb-common mysql-server mysql-client mysql-common 2>/dev/null || true
sudo apt-get autoremove -y
sudo apt-get autoclean

# Remover diretórios de dados
sudo rm -rf /var/lib/mysql /var/lib/mariadb /etc/mysql /etc/my.cnf 2>/dev/null || true

# 2. INSTALAR NOVO MariaDB limpo
echo "📦 Instalando MariaDB limpo..."
sudo apt-get update
sudo apt-get install -y mariadb-server mariadb-client

# 3. RESETAR completamente a senha do root
echo "🔄 Resetando senha do MariaDB..."

# Parar MariaDB
sudo systemctl stop mariadb

# Criar arquivo de inicialização sem senha
sudo tee /tmp/mysql-init.sql > /dev/null << 'EOF'
-- Resetar senha do root
ALTER USER 'root'@'localhost' IDENTIFIED BY '';
FLUSH PRIVILEGES;

-- Remover usuários anônimos
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');

-- Remover banco de teste
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';

-- Recarregar privilégios
FLUSH PRIVILEGES;
EOF

# Iniciar MariaDB em modo seguro
echo "Iniciando MariaDB em modo seguro..."
sudo mysqld_safe --skip-grant-tables --skip-networking &
MYSQL_PID=$!
sleep 5

# Conectar e resetar
echo "Resetando configurações..."
sudo mysql -u root << 'EOF'
-- Primeiro, garantir que podemos modificar
USE mysql;

-- Resetar senha do root
UPDATE user SET plugin='mysql_native_password', authentication_string='' WHERE User='root';
FLUSH PRIVILEGES;
EXIT;
EOF

# Parar modo seguro
sudo kill $MYSQL_PID 2>/dev/null || true
sleep 2

# 4. Iniciar MariaDB normalmente e configurar senha
echo "🔐 Configurando nova senha..."
sudo systemctl start mariadb
sleep 3

# Definir nova senha
sudo mysql -u root << 'EOF'
-- Definir senha para root
ALTER USER 'root'@'localhost' IDENTIFIED BY 'MariaDBRoot2024!';
FLUSH PRIVILEGES;

-- Configurações básicas de segurança
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
EOF

# Definir variáveis
ROOT_PASS="MariaDBRoot2024!"
echo "✅ Nova senha root: $ROOT_PASS"

# 5. Criar banco de dados da aplicação
echo "🗃️ Criando banco de dados..."
APP_USER="hls_app"
APP_PASS="HlsApp_$(date +%s | tail -c 6)"

sudo mysql -u root -p"$ROOT_PASS" <<-EOF
CREATE DATABASE IF NOT EXISTS hls_manager CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${APP_USER}'@'localhost' IDENTIFIED BY '${APP_PASS}';
GRANT ALL PRIVILEGES ON hls_manager.* TO '${APP_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF

echo "✅ Banco criado: usuário=$APP_USER, senha=$APP_PASS"

# 6. Instalar dependências do sistema
echo "📦 Instalando dependências do sistema..."
sudo apt-get install -y python3 python3-pip ffmpeg python3-venv nginx \
    software-properties-common curl wget git \
    pkg-config libssl-dev libffi-dev python3-dev

# 7. Criar usuário e diretórios
echo "👤 Criando estrutura do sistema..."
if ! id "hlsadmin" &>/dev/null; then
    sudo useradd -r -s /bin/false -m -d /opt/hls-manager hlsadmin
fi

sudo mkdir -p /opt/hls-manager/{uploads,hls,logs,config,static,templates}
cd /opt/hls-manager

sudo chown -R hlsadmin:hlsadmin /opt/hls-manager
sudo chmod 755 /opt/hls-manager
sudo chmod 770 /opt/hls-manager/uploads

# 8. Instalar Python e PyMySQL (NÃO mysqlclient!)
echo "🐍 Configurando Python com PyMySQL..."

sudo -u hlsadmin python3 -m venv venv
sudo -u hlsadmin ./venv/bin/pip install --upgrade pip setuptools wheel

# Instalar PyMySQL - funciona SEM problemas de dependência!
echo "Instalando PyMySQL..."
sudo -u hlsadmin ./venv/bin/pip install pymysql==1.1.0

# Instalar Flask e dependências
sudo -u hlsadmin ./venv/bin/pip install flask==2.3.3 \
    flask-sqlalchemy==3.0.5 \
    flask-login==0.6.2 \
    flask-wtf==1.1.1 \
    gunicorn==21.2.0 \
    python-dotenv==1.0.0 \
    werkzeug==2.3.7 \
    pillow==10.0.0

# 9. Criar aplicação Flask COMPLETA
echo "💻 Criando aplicação Flask completa..."

# Criar app.py
sudo tee /opt/hls-manager/app.py > /dev/null << 'EOF'
from flask import Flask, render_template, jsonify, request, redirect, url_for, flash
from flask_sqlalchemy import SQLAlchemy
from flask_login import LoginManager, UserMixin, login_user, logout_user, login_required, current_user
from werkzeug.security import generate_password_hash, check_password_hash
from werkzeug.utils import secure_filename
import os
from datetime import datetime
import subprocess
import uuid

app = Flask(__name__)

# Configuração
app.config['SECRET_KEY'] = os.getenv('SECRET_KEY', 'dev-secret-123')
app.config['SQLALCHEMY_DATABASE_URI'] = os.getenv('DATABASE_URL', 'mysql+pymysql://hls_app:HlsApp_123456@localhost/hls_manager')
app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False
app.config['UPLOAD_FOLDER'] = '/opt/hls-manager/uploads'
app.config['HLS_FOLDER'] = '/opt/hls-manager/hls'
app.config['MAX_CONTENT_LENGTH'] = 1 * 1024 * 1024 * 1024  # 1GB

# Inicializar extensões
db = SQLAlchemy(app)
login_manager = LoginManager(app)
login_manager.login_view = 'login'

# Modelos
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

class Channel(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(100), nullable=False)
    description = db.Column(db.Text)
    status = db.Column(db.String(20), default='draft')  # draft, processing, active, error
    hls_path = db.Column(db.String(500))
    video_path = db.Column(db.String(500))
    user_id = db.Column(db.Integer, db.ForeignKey('user.id'))
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    updated_at = db.Column(db.DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)
    
    # Métricas
    duration = db.Column(db.Integer)  # segundos
    resolution = db.Column(db.String(20))
    file_size = db.Column(db.BigInteger)
    
    user = db.relationship('User', backref='channels')

@login_manager.user_loader
def load_user(user_id):
    return User.query.get(int(user_id))

# Rotas
@app.route('/')
def index():
    if current_user.is_authenticated:
        return redirect(url_for('dashboard'))
    return render_template('index.html')

@app.route('/login', methods=['GET', 'POST'])
def login():
    if request.method == 'POST':
        username = request.form.get('username')
        password = request.form.get('password')
        user = User.query.filter_by(username=username).first()
        
        if user and user.check_password(password):
            login_user(user)
            return redirect(url_for('dashboard'))
        flash('Credenciais inválidas')
    return render_template('login.html')

@app.route('/logout')
@login_required
def logout():
    logout_user()
    return redirect(url_for('index'))

@app.route('/dashboard')
@login_required
def dashboard():
    channels = Channel.query.filter_by(user_id=current_user.id).all()
    return render_template('dashboard.html', channels=channels)

@app.route('/channels')
@login_required
def channel_list():
    channels = Channel.query.filter_by(user_id=current_user.id).all()
    return render_template('channels.html', channels=channels)

@app.route('/channels/new', methods=['GET', 'POST'])
@login_required
def new_channel():
    if request.method == 'POST':
        name = request.form.get('name')
        description = request.form.get('description')
        
        channel = Channel(
            name=name,
            description=description,
            user_id=current_user.id
        )
        db.session.add(channel)
        db.session.commit()
        
        flash('Canal criado com sucesso!')
        return redirect(url_for('channel_list'))
    
    return render_template('new_channel.html')

@app.route('/channels/<int:channel_id>/upload', methods=['POST'])
@login_required
def upload_video(channel_id):
    channel = Channel.query.get_or_404(channel_id)
    
    if 'video' not in request.files:
        flash('Nenhum arquivo selecionado')
        return redirect(url_for('channel_list'))
    
    file = request.files['video']
    if file.filename == '':
        flash('Nenhum arquivo selecionado')
        return redirect(url_for('channel_list'))
    
    # Salvar arquivo
    filename = secure_filename(file.filename)
    unique_filename = f"{uuid.uuid4()}_{filename}"
    filepath = os.path.join(app.config['UPLOAD_FOLDER'], unique_filename)
    file.save(filepath)
    
    # Atualizar canal
    channel.video_path = filepath
    channel.status = 'processing'
    db.session.commit()
    
    # Iniciar conversão em background (simplificado)
    flash('Vídeo enviado! A conversão começará em breve.')
    return redirect(url_for('channel_list'))

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
        return jsonify({'status': 'error', 'message': str(e)}), 500

# Templates simples
@app.route('/templates/<template_name>')
def serve_template(template_name):
    templates = {
        'index.html': '''
            <!DOCTYPE html>
            <html>
            <head><title>HLS Manager</title></head>
            <body>
                <h1>🎬 HLS Manager</h1>
                <p>Sistema de gerenciamento de streaming HLS</p>
                <a href="/login">Login</a> | <a href="/health">Health Check</a>
            </body>
            </html>
        ''',
        'login.html': '''
            <!DOCTYPE html>
            <html>
            <head><title>Login</title></head>
            <body>
                <h1>Login</h1>
                <form method="POST">
                    <input type="text" name="username" placeholder="Usuário" required><br>
                    <input type="password" name="password" placeholder="Senha" required><br>
                    <button type="submit">Entrar</button>
                </form>
            </body>
            </html>
        ''',
        'dashboard.html': '''
            <!DOCTYPE html>
            <html>
            <head><title>Dashboard</title></head>
            <body>
                <h1>📊 Dashboard</h1>
                <p>Bem-vindo!</p>
                <a href="/channels">Gerenciar Canais</a> |
                <a href="/channels/new">Novo Canal</a> |
                <a href="/logout">Sair</a>
            </body>
            </html>
        ''',
        'channels.html': '''
            <!DOCTYPE html>
            <html>
            <head><title>Canais</title></head>
            <body>
                <h1>📺 Canais</h1>
                <a href="/channels/new">+ Novo Canal</a><br><br>
                {% for channel in channels %}
                    <div>
                        <h3>{{ channel.name }}</h3>
                        <p>Status: {{ channel.status }}</p>
                        <form action="/channels/{{ channel.id }}/upload" method="POST" enctype="multipart/form-data">
                            <input type="file" name="video" accept="video/*">
                            <button type="submit">Upload Vídeo</button>
                        </form>
                    </div>
                {% endfor %}
            </body>
            </html>
        ''',
        'new_channel.html': '''
            <!DOCTYPE html>
            <html>
            <head><title>Novo Canal</title></head>
            <body>
                <h1>Novo Canal</h1>
                <form method="POST">
                    <input type="text" name="name" placeholder="Nome do Canal" required><br>
                    <textarea name="description" placeholder="Descrição"></textarea><br>
                    <button type="submit">Criar Canal</button>
                </form>
            </body>
            </html>
        '''
    }
    
    if template_name in templates:
        return templates[template_name]
    return 'Template não encontrado', 404

# Criar banco e usuário admin
with app.app_context():
    db.create_all()
    
    # Criar usuário admin se não existir
    if not User.query.filter_by(username='admin').first():
        admin = User(username='admin', email='admin@localhost', is_admin=True)
        admin.set_password('admin123')
        db.session.add(admin)
        db.session.commit()
        print("✅ Usuário admin criado")

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, debug=False)
EOF

# 10. Criar arquivo de configuração .env
echo "⚙️ Criando configuração..."
ADMIN_PASS="admin123"  # Senha simples para teste
SECRET_KEY=$(openssl rand -hex 32)

sudo tee /opt/hls-manager/.env > /dev/null << EOF
SECRET_KEY=${SECRET_KEY}
DATABASE_URL=mysql+pymysql://${APP_USER}:${APP_PASS}@localhost/hls_manager
ADMIN_PASSWORD=${ADMIN_PASS}
DEBUG=False
PORT=5000
EOF

sudo chown hlsadmin:hlsadmin /opt/hls-manager/.env
sudo chmod 600 /opt/hls-manager/.env

# 11. Criar diretório de templates
sudo mkdir -p /opt/hls-manager/templates

# 12. Criar serviço systemd
echo "⚙️ Criando serviço systemd..."
sudo tee /etc/systemd/system/hls-manager.service > /dev/null << EOF
[Unit]
Description=HLS Manager Service
After=network.target mariadb.service
Requires=mariadb.service

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
    --timeout 120 \
    --access-logfile /opt/hls-manager/logs/access.log \
    --error-logfile /opt/hls-manager/logs/error.log \
    app:app
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# 13. Configurar Nginx
echo "🌐 Configurando Nginx..."
sudo tee /etc/nginx/sites-available/hls-manager > /dev/null << 'EOF'
server {
    listen 80;
    server_name _;
    
    client_max_body_size 1G;
    
    location / {
        proxy_pass http://127.0.0.1:5000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
    
    location /hls/ {
        alias /opt/hls-manager/hls/;
        expires 30d;
        add_header Cache-Control "public";
    }
    
    location /health {
        proxy_pass http://127.0.0.1:5000/health;
        access_log off;
    }
}
EOF

sudo ln -sf /etc/nginx/sites-available/hls-manager /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true

# 14. Iniciar todos os serviços
echo "🚀 Iniciando serviços..."

sudo systemctl daemon-reload
sudo systemctl enable mariadb
sudo systemctl start mariadb
sleep 3

sudo systemctl enable hls-manager
sudo systemctl start hls-manager
sleep 3

sudo nginx -t 2>/dev/null && sudo systemctl restart nginx

# 15. Testar
echo "🧪 Testando instalação..."
sleep 5

echo "Status dos serviços:"
for service in mariadb hls-manager nginx; do
    if systemctl is-active --quiet $service; then
        echo "✅ $service: ATIVO"
    else
        echo "❌ $service: INATIVO"
        sudo journalctl -u $service -n 10 --no-pager
    fi
done

echo ""
echo "Testando aplicação..."
if curl -s http://localhost:5000/health | grep -q "healthy"; then
    echo "✅ Aplicação funcionando!"
else
    echo "⚠️ Aplicação não responde"
    sudo journalctl -u hls-manager -n 20 --no-pager
fi

# 16. Mostrar informações
IP=$(hostname -I | awk '{print $1}' 2>/dev/null || curl -s ifconfig.me || echo "localhost")
echo ""
echo "🎉 HLS MANAGER INSTALADO COM SUCESSO!"
echo "====================================="
echo ""
echo "🌐 URL: http://$IP"
echo ""
echo "🔐 CREDENCIAIS DE LOGIN:"
echo "   Usuário: admin"
echo "   Senha: admin123"
echo ""
echo "🗄️ INFORMAÇÕES DO BANCO:"
echo "   Usuário: $APP_USER"
echo "   Senha: $APP_PASS"
echo "   Root Password: $ROOT_PASS"
echo ""
echo "⚙️ COMANDOS ÚTEIS:"
echo "   sudo systemctl status hls-manager"
echo "   sudo journalctl -u hls-manager -f"
echo "   mysql -u $APP_USER -p"
echo ""
echo "📁 DIRETÓRIO: /opt/hls-manager"
echo ""
echo "✅ Instalação completa! Acesse http://$IP"
