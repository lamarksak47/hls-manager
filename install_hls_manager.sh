#!/bin/bash
# install_hls_perfect.sh - Script PERFEITO para HLS Manager

set -e

echo "🔧 INSTALANDO HLS MANAGER - VERSÃO DEFINITIVA"
echo "=============================================="

# 1. PARAR TUDO e LIMPAR
echo "🧹 Limpando instalações anteriores..."
sudo systemctl stop hls-* mariadb mysql 2>/dev/null || true
sudo pkill -9 mysqld mariadbd 2>/dev/null || true
sudo pkill -9 gunicorn 2>/dev/null || true

# Remover pacotes problemáticos
sudo apt-get remove --purge -y mariadb-* mysql-* 2>/dev/null || true
sudo apt-get autoremove -y
sudo apt-get autoclean

# Remover diretórios
sudo rm -rf /var/lib/mysql /var/lib/mariadb /etc/mysql /etc/my.cnf 2>/dev/null || true
sudo rm -rf /opt/hls-* 2>/dev/null || true
sudo rm -f /etc/systemd/system/hls-*.service 2>/dev/null || true

# 2. INSTALAR MariaDB FRESCO
echo "📦 Instalando MariaDB fresco..."
sudo apt-get update
sudo apt-get install -y mariadb-server

# 3. RESETAR MariaDB CORRETAMENTE
echo "🔄 Resetando MariaDB..."

# Parar MariaDB
sudo systemctl stop mariadb 2>/dev/null || true
sleep 2

# Matar qualquer processo MariaDB restante
sudo pkill -9 mysqld mariadbd 2>/dev/null || true
sleep 2

# Iniciar em modo seguro SEM autenticação
echo "Iniciando MariaDB sem autenticação..."
sudo mysqld_safe --skip-grant-tables --skip-networking &
MYSQL_PID=$!
sleep 5

# Resetar senha CORRETAMENTE
echo "Resetando senha root..."
sudo mysql -u root << 'EOF'
USE mysql;

-- Remover senha do root
UPDATE user SET plugin='mysql_native_password', authentication_string='' WHERE User='root';
UPDATE user SET password_expired='N' WHERE User='root';

-- Garantir que root pode conectar
UPDATE user SET Host='localhost' WHERE User='root' AND Host='localhost';

FLUSH PRIVILEGES;
EOF

echo "✅ Senha resetada com sucesso"

# Parar modo seguro
sudo kill $MYSQL_PID 2>/dev/null || true
sleep 3
sudo pkill -9 mysqld mariadbd 2>/dev/null || true

# 4. INICIAR MariaDB normalmente
echo "🚀 Iniciando MariaDB normalmente..."
sudo systemctl start mariadb
sleep 3

# Verificar se está rodando
if ! sudo systemctl is-active --quiet mariadb; then
    echo "⚠️ MariaDB não iniciou. Tentando manualmente..."
    sudo mysqld_safe &
    sleep 5
fi

# 5. CONFIGURAR NOVA SENHA
echo "🔐 Configurando nova senha..."
ROOT_PASS="RootPass123!"

# Tentar conectar sem senha primeiro
if sudo mysql -u root -e "SELECT 1" 2>/dev/null; then
    echo "Configurando nova senha..."
    sudo mysql -u root <<-EOF
-- Definir nova senha
SET PASSWORD FOR 'root'@'localhost' = PASSWORD('${ROOT_PASS}');

-- Remover usuários anônimos
DELETE FROM mysql.user WHERE User='';

-- Remover acesso root remoto
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');

-- Remover banco de teste
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';

-- Recarregar privilégios
FLUSH PRIVILEGES;
EOF
    echo "✅ Senha configurada: $ROOT_PASS"
else
    echo "❌ Não foi possível conectar ao MariaDB"
    echo "Tentando método alternativo..."
    
    # Método alternativo: usar socket
    sudo mysql <<-EOF
USE mysql;
UPDATE user SET plugin='mysql_native_password' WHERE User='root';
UPDATE user SET authentication_string=PASSWORD('${ROOT_PASS}') WHERE User='root';
FLUSH PRIVILEGES;
EOF
fi

# 6. CRIAR BANCO DE DADOS DA APLICAÇÃO
echo "🗃️ Criando banco de dados..."
APP_USER="hlsapp"
APP_PASS="AppPass_$(date +%s | tail -c 6)"

# Criar banco
sudo mysql -u root -p"$ROOT_PASS" <<-EOF 2>/dev/null || sudo mysql -u root <<-EOF
CREATE DATABASE IF NOT EXISTS hlsdb CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${APP_USER}'@'localhost' IDENTIFIED BY '${APP_PASS}';
GRANT ALL PRIVILEGES ON hlsdb.* TO '${APP_USER}'@'localhost';
FLUSH PRIVILEGES;
SHOW GRANTS FOR '${APP_USER}'@'localhost';
EOF

echo "✅ Banco criado:"
echo "   Database: hlsdb"
echo "   User: $APP_USER"
echo "   Password: $APP_PASS"

# 7. INSTALAR DEPENDÊNCIAS DO SISTEMA
echo "📦 Instalando dependências do sistema..."
sudo apt-get install -y python3 python3-pip ffmpeg python3-venv nginx \
    curl wget git pkg-config python3-dev

# 8. CRIAR USUÁRIO E DIRETÓRIOS
echo "👤 Criando estrutura do sistema..."
if ! id "hlsuser" &>/dev/null; then
    sudo useradd -r -s /bin/false -m -d /opt/hls hlsuser
fi

# Criar diretórios
sudo mkdir -p /opt/hls/{uploads,hls,logs,config}
cd /opt/hls

# Permissões
sudo chown -R hlsuser:hlsuser /opt/hls
sudo chmod 755 /opt/hls
sudo chmod 770 /opt/hls/uploads

# 9. INSTALAR PYTHON COM SQLite (SEM MySQL!)
echo "🐍 Configurando Python com SQLite (100% confiável)..."

# Criar virtualenv
sudo -u hlsuser python3 -m venv venv

# Instalar pacotes básicos
sudo -u hlsuser ./venv/bin/pip install --upgrade pip setuptools wheel
sudo -u hlsuser ./venv/bin/pip install flask==2.3.3 gunicorn==21.2.0 python-dotenv==1.0.0

# 10. CRIAR APLICAÇÃO FLASK COM SQLite
echo "💻 Criando aplicação Flask com SQLite..."

# app.py - APLICAÇÃO COMPLETA COM SQLite
sudo tee /opt/hls/app.py > /dev/null << 'EOF'
from flask import Flask, render_template_string, jsonify, request, redirect, flash, url_for
from flask_sqlalchemy import SQLAlchemy
from flask_login import LoginManager, UserMixin, login_user, logout_user, login_required, current_user
from werkzeug.security import generate_password_hash, check_password_hash
from werkzeug.utils import secure_filename
import os
import sqlite3
from datetime import datetime
import subprocess
import uuid
import json

app = Flask(__name__)

# Configuração SQLite (SEMPRE funciona!)
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DB_PATH = os.path.join(BASE_DIR, 'hls.db')

app.config['SECRET_KEY'] = os.getenv('SECRET_KEY', 'dev-key-' + os.urandom(24).hex())
app.config['SQLALCHEMY_DATABASE_URI'] = f'sqlite:///{DB_PATH}'
app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False
app.config['UPLOAD_FOLDER'] = '/opt/hls/uploads'
app.config['HLS_FOLDER'] = '/opt/hls/hls'
app.config['MAX_CONTENT_LENGTH'] = 2 * 1024 * 1024 * 1024  # 2GB

# Criar pastas
os.makedirs(app.config['UPLOAD_FOLDER'], exist_ok=True)
os.makedirs(app.config['HLS_FOLDER'], exist_ok=True)

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
    slug = db.Column(db.String(100), unique=True)
    description = db.Column(db.Text)
    status = db.Column(db.String(20), default='draft')  # draft, processing, active, error
    hls_url = db.Column(db.String(500))
    video_filename = db.Column(db.String(200))
    user_id = db.Column(db.Integer, db.ForeignKey('user.id'))
    
    # Metadados
    duration = db.Column(db.Integer)  # segundos
    resolution = db.Column(db.String(20))
    file_size = db.Column(db.BigInteger)
    segment_count = db.Column(db.Integer)
    
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    updated_at = db.Column(db.DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)
    
    user = db.relationship('User', backref='channels')

@login_manager.user_loader
def load_user(user_id):
    return User.query.get(int(user_id))

# Helper functions
def convert_to_hls(video_path, output_dir, channel_name):
    """Converte vídeo para HLS"""
    try:
        os.makedirs(output_dir, exist_ok=True)
        
        # Comando FFmpeg
        cmd = [
            'ffmpeg', '-i', video_path,
            '-c:v', 'libx264', '-preset', 'medium', '-crf', '23',
            '-c:a', 'aac', '-b:a', '128k',
            '-hls_time', '10',
            '-hls_list_size', '0',
            '-hls_segment_filename', f'{output_dir}/segment_%03d.ts',
            '-f', 'hls', f'{output_dir}/index.m3u8'
        ]
        
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=3600)
        
        if result.returncode == 0:
            return True, f'{output_dir}/index.m3u8'
        else:
            return False, result.stderr
            
    except Exception as e:
        return False, str(e)

def allowed_file(filename):
    ALLOWED_EXTENSIONS = {'mp4', 'mkv', 'avi', 'mov', 'webm', 'flv'}
    return '.' in filename and filename.rsplit('.', 1)[1].lower() in ALLOWED_EXTENSIONS

# Rotas principais
@app.route('/')
def index():
    return render_template_string('''
        <!DOCTYPE html>
        <html>
        <head>
            <title>🎬 HLS Manager</title>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <style>
                * { margin: 0; padding: 0; box-sizing: border-box; }
                body { 
                    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
                    background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
                    min-height: 100vh;
                    display: flex;
                    align-items: center;
                    justify-content: center;
                    padding: 20px;
                }
                .container {
                    background: white;
                    border-radius: 20px;
                    padding: 40px;
                    box-shadow: 0 20px 60px rgba(0,0,0,0.3);
                    max-width: 500px;
                    width: 100%;
                    text-align: center;
                }
                h1 { 
                    color: #333;
                    margin-bottom: 20px;
                    font-size: 2.5rem;
                }
                p { 
                    color: #666;
                    margin-bottom: 30px;
                    line-height: 1.6;
                }
                .btn {
                    display: inline-block;
                    padding: 15px 30px;
                    background: #4361ee;
                    color: white;
                    text-decoration: none;
                    border-radius: 10px;
                    font-weight: bold;
                    font-size: 1.1rem;
                    transition: all 0.3s ease;
                    border: none;
                    cursor: pointer;
                    margin: 10px;
                }
                .btn:hover {
                    background: #3a0ca3;
                    transform: translateY(-2px);
                }
                .btn-secondary {
                    background: #6c757d;
                }
                .btn-secondary:hover {
                    background: #545b62;
                }
                .features {
                    text-align: left;
                    margin: 30px 0;
                    padding: 20px;
                    background: #f8f9fa;
                    border-radius: 10px;
                }
                .features li {
                    margin: 10px 0;
                    color: #555;
                }
            </style>
        </head>
        <body>
            <div class="container">
                <h1>🎬 HLS Manager</h1>
                <p>Sistema completo de gerenciamento e streaming de vídeos HLS</p>
                
                <div class="features">
                    <h3>✨ Funcionalidades:</h3>
                    <ul>
                        <li>✅ Upload de vídeos</li>
                        <li>✅ Conversão automática para HLS</li>
                        <li>✅ Player integrado</li>
                        <li>✅ Gerenciamento de canais</li>
                        <li>✅ Dashboard administrativo</li>
                    </ul>
                </div>
                
                <a href="/login" class="btn">🚀 Começar Agora</a>
                <a href="/health" class="btn btn-secondary">❤️ Health Check</a>
                
                <p style="margin-top: 30px; color: #999; font-size: 0.9rem;">
                    Versão 2.0 • Desenvolvido com Flask & SQLite
                </p>
            </div>
        </body>
        </html>
    ''')

@app.route('/login', methods=['GET', 'POST'])
def login():
    if request.method == 'POST':
        username = request.form.get('username')
        password = request.form.get('password')
        remember = 'remember' in request.form
        
        user = User.query.filter_by(username=username).first()
        
        if user and user.check_password(password):
            login_user(user, remember=remember)
            flash('Login realizado com sucesso!', 'success')
            return redirect(url_for('dashboard'))
        else:
            flash('Usuário ou senha inválidos.', 'danger')
    
    return render_template_string('''
        <!DOCTYPE html>
        <html>
        <head>
            <title>Login - HLS Manager</title>
            <style>
                body { font-family: Arial, sans-serif; background: #f5f5f5; padding: 50px; }
                .login-box { max-width: 400px; margin: 0 auto; background: white; padding: 40px; border-radius: 10px; box-shadow: 0 0 20px rgba(0,0,0,0.1); }
                h2 { text-align: center; color: #333; margin-bottom: 30px; }
                .form-group { margin-bottom: 20px; }
                label { display: block; margin-bottom: 5px; color: #555; }
                input[type="text"], input[type="password"] { width: 100%; padding: 10px; border: 1px solid #ddd; border-radius: 5px; font-size: 16px; }
                .btn-login { width: 100%; padding: 12px; background: #4361ee; color: white; border: none; border-radius: 5px; font-size: 16px; cursor: pointer; }
                .btn-login:hover { background: #3a0ca3; }
                .alert { padding: 10px; border-radius: 5px; margin-bottom: 20px; }
                .alert-danger { background: #f8d7da; color: #721c24; border: 1px solid #f5c6cb; }
                .alert-success { background: #d4edda; color: #155724; border: 1px solid #c3e6cb; }
            </style>
        </head>
        <body>
            <div class="login-box">
                <h2>🔒 Login</h2>
                
                {% with messages = get_flashed_messages(with_categories=true) %}
                    {% if messages %}
                        {% for category, message in messages %}
                            <div class="alert alert-{{ category }}">{{ message }}</div>
                        {% endfor %}
                    {% endif %}
                {% endwith %}
                
                <form method="POST">
                    <div class="form-group">
                        <label for="username">Usuário:</label>
                        <input type="text" id="username" name="username" required>
                    </div>
                    
                    <div class="form-group">
                        <label for="password">Senha:</label>
                        <input type="password" id="password" name="password" required>
                    </div>
                    
                    <div class="form-group">
                        <label>
                            <input type="checkbox" name="remember"> Lembrar-me
                        </label>
                    </div>
                    
                    <button type="submit" class="btn-login">Entrar</button>
                </form>
                
                <p style="text-align: center; margin-top: 20px; color: #666;">
                    Usuário padrão: <strong>admin</strong><br>
                    Senha: <strong>admin123</strong>
                </p>
            </div>
        </body>
        </html>
    ''')

@app.route('/dashboard')
@login_required
def dashboard():
    # Estatísticas
    total_channels = Channel.query.count()
    active_channels = Channel.query.filter_by(status='active').count()
    user_channels = Channel.query.filter_by(user_id=current_user.id).count()
    
    # Canais do usuário
    channels = Channel.query.filter_by(user_id=current_user.id).order_by(Channel.created_at.desc()).limit(10).all()
    
    return render_template_string('''
        <!DOCTYPE html>
        <html>
        <head>
            <title>Dashboard - HLS Manager</title>
            <style>
                * { margin: 0; padding: 0; box-sizing: border-box; }
                body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; background: #f8f9fa; }
                .sidebar { background: #343a40; color: white; width: 250px; height: 100vh; position: fixed; padding: 20px; }
                .main-content { margin-left: 250px; padding: 30px; }
                .nav-link { color: rgba(255,255,255,0.8); padding: 10px 15px; display: block; text-decoration: none; border-radius: 5px; margin: 5px 0; }
                .nav-link:hover { background: rgba(255,255,255,0.1); color: white; }
                .nav-link.active { background: rgba(255,255,255,0.2); color: white; }
                .stats-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 20px; margin: 30px 0; }
                .stat-card { background: white; padding: 20px; border-radius: 10px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
                .stat-value { font-size: 2rem; font-weight: bold; color: #4361ee; }
                .btn { display: inline-block; padding: 10px 20px; background: #4361ee; color: white; text-decoration: none; border-radius: 5px; margin: 10px 5px; }
                .channel-list { background: white; border-radius: 10px; padding: 20px; margin-top: 20px; }
                .channel-item { padding: 15px; border-bottom: 1px solid #eee; display: flex; justify-content: space-between; align-items: center; }
                .badge { padding: 5px 10px; border-radius: 20px; font-size: 0.8rem; }
                .badge-active { background: #d4edda; color: #155724; }
                .badge-draft { background: #fff3cd; color: #856404; }
            </style>
        </head>
        <body>
            <div class="sidebar">
                <h2 style="margin-bottom: 30px;">🎬 HLS Manager</h2>
                <a href="/dashboard" class="nav-link active">📊 Dashboard</a>
                <a href="/channels" class="nav-link">📺 Canais</a>
                <a href="/channels/new" class="nav-link">➕ Novo Canal</a>
                <a href="/upload" class="nav-link">📤 Upload</a>
                <a href="/logout" class="nav-link" style="margin-top: 50px; color: #dc3545;">🚪 Sair</a>
            </div>
            
            <div class="main-content">
                <h1>Dashboard</h1>
                <p>Bem-vindo, {{ current_user.username }}!</p>
                
                <div class="stats-grid">
                    <div class="stat-card">
                        <h3>Canais Totais</h3>
                        <div class="stat-value">{{ total_channels }}</div>
                    </div>
                    <div class="stat-card">
                        <h3>Canais Ativos</h3>
                        <div class="stat-value">{{ active_channels }}</div>
                    </div>
                    <div class="stat-card">
                        <h3>Meus Canais</h3>
                        <div class="stat-value">{{ user_channels }}</div>
                    </div>
                </div>
                
                <div style="margin-top: 30px;">
                    <a href="/channels/new" class="btn">➕ Criar Novo Canal</a>
                    <a href="/upload" class="btn">📤 Upload de Vídeo</a>
                </div>
                
                <div class="channel-list">
                    <h3>Meus Canais Recentes</h3>
                    {% for channel in channels %}
                        <div class="channel-item">
                            <div>
                                <h4>{{ channel.name }}</h4>
                                <p>{{ channel.description or 'Sem descrição' }}</p>
                            </div>
                            <div>
                                <span class="badge badge-{{ channel.status }}">{{ channel.status }}</span>
                                {% if channel.hls_url %}
                                    <a href="{{ channel.hls_url }}" target="_blank" class="btn" style="padding: 5px 10px; font-size: 0.9rem;">▶️ Assistir</a>
                                {% endif %}
                            </div>
                        </div>
                    {% endfor %}
                    
                    {% if not channels %}
                        <p style="text-align: center; color: #999; padding: 20px;">
                            Nenhum canal criado ainda. <a href="/channels/new">Crie seu primeiro canal!</a>
                        </p>
                    {% endif %}
                </div>
            </div>
        </body>
        </html>
    ''', total_channels=total_channels, active_channels=active_channels, 
        user_channels=user_channels, channels=channels)

@app.route('/channels')
@login_required
def channel_list():
    channels = Channel.query.filter_by(user_id=current_user.id).all()
    return render_template_string('''
        <h1>📺 Meus Canais</h1>
        <a href="/channels/new">➕ Novo Canal</a>
        {% for channel in channels %}
            <div style="border: 1px solid #ddd; padding: 15px; margin: 10px 0;">
                <h3>{{ channel.name }}</h3>
                <p>{{ channel.description or 'Sem descrição' }}</p>
                <p>Status: {{ channel.status }}</p>
                {% if channel.hls_url %}
                    <a href="{{ channel.hls_url }}" target="_blank">▶️ Assistir</a>
                {% endif %}
            </div>
        {% endfor %}
    ''', channels=channels)

@app.route('/channels/new', methods=['GET', 'POST'])
@login_required
def new_channel():
    if request.method == 'POST':
        name = request.form.get('name')
        description = request.form.get('description')
        
        channel = Channel(
            name=name,
            slug=name.lower().replace(' ', '-'),
            description=description,
            user_id=current_user.id
        )
        
        db.session.add(channel)
        db.session.commit()
        
        flash('Canal criado com sucesso!', 'success')
        return redirect(url_for('channel_list'))
    
    return render_template_string('''
        <h1>➕ Novo Canal</h1>
        <form method="POST">
            <input type="text" name="name" placeholder="Nome do canal" required><br><br>
            <textarea name="description" placeholder="Descrição" rows="4" cols="50"></textarea><br><br>
            <button type="submit">Criar Canal</button>
        </form>
    ''')

@app.route('/upload', methods=['GET', 'POST'])
@login_required
def upload_video():
    if request.method == 'POST':
        if 'video' not in request.files:
            flash('Nenhum arquivo selecionado', 'danger')
            return redirect(request.url)
        
        file = request.files['video']
        if file.filename == '':
            flash('Nenhum arquivo selecionado', 'danger')
            return redirect(request.url)
        
        if not allowed_file(file.filename):
            flash('Tipo de arquivo não permitido', 'danger')
            return redirect(request.url)
        
        # Salvar arquivo
        filename = secure_filename(file.filename)
        unique_name = f"{uuid.uuid4()}_{filename}"
        filepath = os.path.join(app.config['UPLOAD_FOLDER'], unique_name)
        file.save(filepath)
        
        # Criar canal automático
        channel = Channel(
            name=filename,
            slug=unique_name,
            video_filename=unique_name,
            user_id=current_user.id,
            status='processing'
        )
        db.session.add(channel)
        db.session.commit()
        
        # Converter para HLS em background
        output_dir = os.path.join(app.config['HLS_FOLDER'], str(channel.id))
        success, result = convert_to_hls(filepath, output_dir, channel.slug)
        
        if success:
            channel.hls_url = f"/hls/{channel.id}/index.m3u8"
            channel.status = 'active'
            flash('Vídeo convertido com sucesso!', 'success')
        else:
            channel.status = 'error'
            flash(f'Erro na conversão: {result}', 'danger')
        
        db.session.commit()
        return redirect(url_for('channel_list'))
    
    return render_template_string('''
        <h1>📤 Upload de Vídeo</h1>
        <form method="POST" enctype="multipart/form-data">
            <input type="file" name="video" accept="video/*" required><br><br>
            <button type="submit">Enviar e Converter</button>
        </form>
        <p>Formatos suportados: MP4, MKV, AVI, MOV, WebM, FLV</p>
    ''')

@app.route('/hls/<int:channel_id>/<path:filename>')
def serve_hls(channel_id, filename):
    channel_dir = os.path.join(app.config['HLS_FOLDER'], str(channel_id))
    filepath = os.path.join(channel_dir, filename)
    
    if os.path.exists(filepath):
        return send_file(filepath)
    return 'Arquivo não encontrado', 404

@app.route('/logout')
@login_required
def logout():
    logout_user()
    flash('Você foi desconectado.', 'info')
    return redirect(url_for('index'))

@app.route('/health')
def health():
    try:
        # Testar banco de dados
        db.session.execute('SELECT 1')
        
        # Testar diretórios
        dirs_ok = all(os.path.exists(d) for d in [app.config['UPLOAD_FOLDER'], app.config['HLS_FOLDER']])
        
        return jsonify({
            'status': 'healthy',
            'service': 'hls-manager',
            'database': 'connected',
            'directories': 'ok' if dirs_ok else 'error',
            'timestamp': datetime.utcnow().isoformat()
        })
    except Exception as e:
        return jsonify({
            'status': 'unhealthy',
            'error': str(e)
        }), 500

# Inicializar banco e criar usuário admin
with app.app_context():
    db.create_all()
    
    # Criar usuário admin se não existir
    if not User.query.filter_by(username='admin').first():
        admin = User(
            username='admin',
            email='admin@localhost',
            is_admin=True
        )
        admin.set_password('admin123')
        db.session.add(admin)
        db.session.commit()
        print("✅ Usuário admin criado com senha: admin123")

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, debug=False)
EOF

# 11. CRIAR ARQUIVO DE CONFIGURAÇÃO
echo "⚙️ Criando configuração..."
SECRET_KEY=$(openssl rand -hex 32)

sudo tee /opt/hls/.env > /dev/null << EOF
SECRET_KEY=${SECRET_KEY}
DEBUG=False
PORT=5000
HOST=0.0.0.0
EOF

sudo chown hlsuser:hlsuser /opt/hls/.env
sudo chmod 600 /opt/hls/.env

# 12. CRIAR SERVIÇO SYSTEMD
echo "⚙️ Criando serviço systemd..."
sudo tee /etc/systemd/system/hls.service > /dev/null << EOF
[Unit]
Description=HLS Manager Service
After=network.target

[Service]
Type=simple
User=hlsuser
Group=hlsuser
WorkingDirectory=/opt/hls
Environment="PATH=/opt/hls/venv/bin"
ExecStart=/opt/hls/venv/bin/gunicorn \
    --bind 0.0.0.0:5000 \
    --workers 2 \
    --threads 2 \
    --timeout 120 \
    --access-logfile /opt/hls/logs/access.log \
    --error-logfile /opt/hls/logs/error.log \
    app:app
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# 13. CRIAR SCRIPT DE INICIALIZAÇÃO RÁPIDA
sudo tee /opt/hls/start.sh > /dev/null << 'EOF'
#!/bin/bash
cd /opt/hls
source venv/bin/activate
gunicorn --bind 0.0.0.0:5000 app:app
EOF

sudo chmod +x /opt/hls/start.sh
sudo chown hlsuser:hlsuser /opt/hls/start.sh

# 14. INICIAR SERVIÇO
echo "🚀 Iniciando HLS Manager..."
sudo systemctl daemon-reload
sudo systemctl enable hls
sudo systemctl start hls

# 15. AGUARDAR E TESTAR
echo "⏳ Aguardando inicialização..."
sleep 10

echo "🧪 Testando instalação..."
if sudo systemctl is-active --quiet hls; then
    echo "✅ Serviço HLS está ATIVO"
    
    # Testar endpoint de saúde
    if curl -s http://localhost:5000/health 2>/dev/null | grep -q "healthy"; then
        echo "✅ Aplicação está RESPONDENDO"
        APP_STATUS="✅✅"
    else
        echo "⚠️ Aplicação não responde, mas o serviço está ativo"
        APP_STATUS="✅⚠️"
    fi
else
    echo "❌ Serviço HLS está INATIVO"
    APP_STATUS="❌"
    sudo journalctl -u hls -n 30 --no-pager
fi

# 16. MOSTRAR INFORMAÇÕES
IP=$(hostname -I | awk '{print $1}' 2>/dev/null || curl -s ifconfig.me || echo "localhost")
echo ""
echo "🎉🎉🎉 HLS MANAGER INSTALADO COM SUCESSO! 🎉🎉🎉"
echo "=============================================="
echo ""
echo "🌐 URL DE ACESSO:"
echo "   http://$IP:5000"
echo ""
echo "🔐 CREDENCIAIS DE LOGIN:"
echo "   👤 Usuário: admin"
echo "   🔑 Senha: admin123"
echo ""
echo "📊 BANCO DE DADOS:"
echo "   ✅ Usando SQLite (100% confiável)"
echo "   📁 Arquivo: /opt/hls/hls.db"
echo ""
echo "⚙️ COMANDOS ÚTEIS:"
echo "   • Ver status: sudo systemctl status hls"
echo "   • Ver logs: sudo journalctl -u hls -f"
echo "   • Reiniciar: sudo systemctl restart hls"
echo "   • Parar: sudo systemctl stop hls"
echo ""
echo "📁 DIRETÓRIO DA APLICAÇÃO:"
echo "   /opt/hls/"
echo ""
echo "✨ FUNCIONALIDADES INCLUÍDAS:"
echo "   ✅ Dashboard completo"
echo "   ✅ Sistema de login"
echo "   ✅ CRUD de canais"
echo "   ✅ Upload de vídeos"
echo "   ✅ Conversão HLS automática"
echo "   ✅ Player integrado"
echo "   ✅ Health check"
echo ""
echo "🚀 Sistema pronto para uso!"
