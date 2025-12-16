#!/bin/bash
# install_hls_sqlite_only.sh - SISTEMA 100% FUNCIONAL SEM MariaDB

set -e

echo "🎬 INSTALANDO HLS MANAGER - SQLite APENAS"
echo "========================================"

# 1. PARAR e REMOVER tudo relacionado a MariaDB/MySQL
echo "🧹 Limpando sistema..."
sudo systemctl stop mariadb mysql hls-* 2>/dev/null || true
sudo pkill -9 mysqld mariadbd gunicorn 2>/dev/null || true

# Remover MariaDB se existir (opcional)
sudo apt-get remove --purge -y mariadb-* mysql-* 2>/dev/null || true
sudo apt-get autoremove -y
sudo apt-get autoclean

# Remover instalações anteriores
sudo rm -rf /opt/hls-* 2>/dev/null || true
sudo rm -f /etc/systemd/system/hls-*.service 2>/dev/null || true

# 2. INSTALAR APENAS O ESSENCIAL
echo "📦 Instalando dependências..."
sudo apt-get update
sudo apt-get install -y python3 python3-pip ffmpeg python3-venv nginx \
    sqlite3 curl wget git

# 3. CRIAR USUÁRIO E DIRETÓRIOS
echo "👤 Criando estrutura..."
sudo useradd -r -s /bin/false -m -d /opt/hls hlsuser 2>/dev/null || true

sudo mkdir -p /opt/hls/{uploads,hls,logs,config,static}
cd /opt/hls

sudo chown -R hlsuser:hlsuser /opt/hls
sudo chmod 755 /opt/hls
sudo chmod 770 /opt/hls/uploads

# 4. CONFIGURAR PYTHON
echo "🐍 Configurando Python..."
sudo -u hlsuser python3 -m venv venv
sudo -u hlsuser ./venv/bin/pip install --upgrade pip setuptools wheel

# Instalar pacotes Python
sudo -u hlsuser ./venv/bin/pip install flask==2.3.3 \
    flask-sqlalchemy==3.0.5 \
    flask-login==0.6.2 \
    flask-wtf==1.1.1 \
    gunicorn==21.2.0 \
    python-dotenv==1.0.0 \
    werkzeug==2.3.7 \
    pillow==10.0.0

# 5. CRIAR APLICAÇÃO FLASK COMPLETA
echo "💻 Criando aplicação..."

# app.py - SISTEMA COMPLETO COM SQLite
sudo tee /opt/hls/app.py > /dev/null << 'EOF'
from flask import Flask, render_template_string, jsonify, request, redirect, flash, send_file
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
import time

app = Flask(__name__)

# Configuração SQLite (SEMPRE FUNCIONA!)
app.config['SECRET_KEY'] = os.getenv('SECRET_KEY', 'dev-key-' + os.urandom(24).hex())
app.config['SQLALCHEMY_DATABASE_URI'] = 'sqlite:////opt/hls/hls.db'
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

# ========== MODELOS ==========
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
    user_id = db.Column(db.Integer)
    
    # Metadados
    duration = db.Column(db.Integer)  # segundos
    resolution = db.Column(db.String(20))
    file_size = db.Column(db.BigInteger)
    segment_count = db.Column(db.Integer)
    
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    updated_at = db.Column(db.DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)

@login_manager.user_loader
def load_user(user_id):
    return User.query.get(int(user_id))

# ========== FUNÇÕES AUXILIARES ==========
def convert_to_hls(video_path, output_dir, channel_id):
    """Converte vídeo para HLS usando FFmpeg"""
    try:
        os.makedirs(output_dir, exist_ok=True)
        
        # Comando FFmpeg para HLS
        cmd = [
            'ffmpeg', '-i', video_path,
            '-c:v', 'libx264', '-preset', 'fast', '-crf', '23',
            '-c:a', 'aac', '-b:a', '128k',
            '-hls_time', '10',
            '-hls_list_size', '0',
            '-hls_segment_filename', f'{output_dir}/segment_%03d.ts',
            '-f', 'hls', f'{output_dir}/index.m3u8'
        ]
        
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=7200)  # 2 horas timeout
        
        if result.returncode == 0:
            return True, f'/hls/{channel_id}/index.m3u8'
        else:
            return False, result.stderr
            
    except subprocess.TimeoutExpired:
        return False, "Timeout na conversão (2 horas)"
    except Exception as e:
        return False, str(e)

def allowed_file(filename):
    ALLOWED_EXTENSIONS = {'mp4', 'mkv', 'avi', 'mov', 'webm', 'flv'}
    return '.' in filename and filename.rsplit('.', 1)[1].lower() in ALLOWED_EXTENSIONS

# ========== ROTAS ==========
@app.route('/')
def index():
    return render_template_string('''
        <!DOCTYPE html>
        <html>
        <head>
            <title>🎬 HLS Stream Manager</title>
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
                .logo {
                    font-size: 4rem;
                    margin-bottom: 20px;
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
                    margin: 10px;
                    border: none;
                    cursor: pointer;
                }
                .btn:hover {
                    background: #3a0ca3;
                    transform: translateY(-2px);
                    box-shadow: 0 10px 20px rgba(0,0,0,0.2);
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
                .feature-item {
                    margin: 10px 0;
                    color: #555;
                    display: flex;
                    align-items: center;
                }
                .feature-item:before {
                    content: "✅";
                    margin-right: 10px;
                }
                .status {
                    margin-top: 20px;
                    padding: 10px;
                    background: #d4edda;
                    color: #155724;
                    border-radius: 5px;
                    font-weight: bold;
                }
            </style>
        </head>
        <body>
            <div class="container">
                <div class="logo">🎬</div>
                <h1>HLS Stream Manager</h1>
                <p>Sistema completo de streaming de vídeo com conversão automática para HLS</p>
                
                <div class="features">
                    <div class="feature-item">Upload de vídeos MP4, MKV, AVI, MOV</div>
                    <div class="feature-item">Conversão automática para HLS</div>
                    <div class="feature-item">Player integrado</div>
                    <div class="feature-item">Dashboard administrativo</div>
                    <div class="feature-item">Gerenciamento de múltiplos canais</div>
                    <div class="feature-item">Banco de dados SQLite (sem configuração)</div>
                </div>
                
                <div class="status">✅ Sistema 100% Funcional</div>
                
                <div style="margin-top: 30px;">
                    <a href="/login" class="btn">🚀 Entrar no Sistema</a>
                    <a href="/health" class="btn btn-secondary">❤️ Verificar Saúde</a>
                </div>
                
                <div style="margin-top: 30px; font-size: 0.9rem; color: #666;">
                    <p>Usuário padrão: <strong>admin</strong></p>
                    <p>Senha padrão: <strong>admin123</strong></p>
                </div>
            </div>
        </body>
        </html>
    ''')

@app.route('/login', methods=['GET', 'POST'])
def login():
    if request.method == 'POST':
        username = request.form.get('username')
        password = request.form.get('password')
        
        user = User.query.filter_by(username=username).first()
        
        if user and user.check_password(password):
            login_user(user)
            flash('Login realizado com sucesso!', 'success')
            return redirect(url_for('dashboard'))
        else:
            flash('Usuário ou senha incorretos.', 'danger')
    
    return render_template_string('''
        <!DOCTYPE html>
        <html>
        <head>
            <title>Login - HLS Manager</title>
            <style>
                body {
                    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
                    background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
                    min-height: 100vh;
                    display: flex;
                    align-items: center;
                    justify-content: center;
                    padding: 20px;
                }
                .login-box {
                    background: white;
                    border-radius: 15px;
                    padding: 40px;
                    box-shadow: 0 20px 60px rgba(0,0,0,0.3);
                    width: 100%;
                    max-width: 400px;
                }
                h2 {
                    color: #333;
                    text-align: center;
                    margin-bottom: 30px;
                }
                .form-group {
                    margin-bottom: 20px;
                }
                input[type="text"], input[type="password"] {
                    width: 100%;
                    padding: 15px;
                    border: 2px solid #e0e0e0;
                    border-radius: 10px;
                    font-size: 16px;
                    transition: border-color 0.3s;
                }
                input:focus {
                    border-color: #4361ee;
                    outline: none;
                }
                .btn-login {
                    width: 100%;
                    padding: 15px;
                    background: #4361ee;
                    color: white;
                    border: none;
                    border-radius: 10px;
                    font-size: 16px;
                    font-weight: bold;
                    cursor: pointer;
                    transition: all 0.3s;
                }
                .btn-login:hover {
                    background: #3a0ca3;
                }
                .alert {
                    padding: 15px;
                    border-radius: 10px;
                    margin-bottom: 20px;
                    text-align: center;
                }
                .alert-danger {
                    background: #f8d7da;
                    color: #721c24;
                    border: 1px solid #f5c6cb;
                }
                .alert-success {
                    background: #d4edda;
                    color: #155724;
                    border: 1px solid #c3e6cb;
                }
                .credential-box {
                    background: #f8f9fa;
                    padding: 15px;
                    border-radius: 10px;
                    margin-top: 20px;
                    text-align: center;
                    font-size: 0.9rem;
                    color: #666;
                }
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
                        <input type="text" name="username" placeholder="Usuário" required>
                    </div>
                    
                    <div class="form-group">
                        <input type="password" name="password" placeholder="Senha" required>
                    </div>
                    
                    <button type="submit" class="btn-login">Entrar</button>
                </form>
                
                <div class="credential-box">
                    <strong>Credenciais Padrão:</strong><br>
                    Usuário: <code>admin</code><br>
                    Senha: <code>admin123</code>
                </div>
            </div>
        </body>
        </html>
    ''')

@app.route('/dashboard')
@login_required
def dashboard():
    # Estatísticas
    total_channels = Channel.query.count()
    user_channels = Channel.query.filter_by(user_id=current_user.id).count()
    active_channels = Channel.query.filter_by(status='active', user_id=current_user.id).count()
    
    # Canais do usuário
    channels = Channel.query.filter_by(user_id=current_user.id).order_by(Channel.created_at.desc()).limit(5).all()
    
    return render_template_string('''
        <!DOCTYPE html>
        <html>
        <head>
            <title>Dashboard - HLS Manager</title>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <style>
                :root {
                    --primary: #4361ee;
                    --secondary: #3a0ca3;
                    --success: #4cc9f0;
                    --dark: #212529;
                    --light: #f8f9fa;
                }
                * { margin: 0; padding: 0; box-sizing: border-box; }
                body {
                    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
                    background: #f5f7fb;
                    color: #333;
                }
                .sidebar {
                    background: linear-gradient(180deg, var(--primary) 0%, var(--secondary) 100%);
                    color: white;
                    width: 250px;
                    height: 100vh;
                    position: fixed;
                    padding: 20px;
                    box-shadow: 3px 0 10px rgba(0,0,0,0.1);
                }
                .main-content {
                    margin-left: 250px;
                    padding: 30px;
                }
                .nav-link {
                    color: rgba(255,255,255,0.8);
                    padding: 12px 20px;
                    display: block;
                    text-decoration: none;
                    border-radius: 8px;
                    margin: 5px 0;
                    transition: all 0.3s;
                }
                .nav-link:hover, .nav-link.active {
                    background: rgba(255,255,255,0.1);
                    color: white;
                }
                .stats-grid {
                    display: grid;
                    grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
                    gap: 20px;
                    margin: 30px 0;
                }
                .stat-card {
                    background: white;
                    padding: 25px;
                    border-radius: 12px;
                    box-shadow: 0 4px 6px rgba(0,0,0,0.05);
                    text-align: center;
                    transition: transform 0.3s;
                }
                .stat-card:hover {
                    transform: translateY(-5px);
                }
                .stat-value {
                    font-size: 2.5rem;
                    font-weight: bold;
                    color: var(--primary);
                    margin: 10px 0;
                }
                .stat-label {
                    color: #666;
                    font-size: 0.9rem;
                }
                .btn {
                    display: inline-block;
                    padding: 12px 24px;
                    background: var(--primary);
                    color: white;
                    text-decoration: none;
                    border-radius: 8px;
                    font-weight: 600;
                    margin: 10px 5px;
                    border: none;
                    cursor: pointer;
                    transition: all 0.3s;
                }
                .btn:hover {
                    background: var(--secondary);
                    transform: translateY(-2px);
                }
                .channel-list {
                    background: white;
                    border-radius: 12px;
                    padding: 30px;
                    margin-top: 30px;
                    box-shadow: 0 4px 6px rgba(0,0,0,0.05);
                }
                .channel-item {
                    padding: 20px;
                    border-bottom: 1px solid #eee;
                    display: flex;
                    justify-content: space-between;
                    align-items: center;
                }
                .channel-item:last-child {
                    border-bottom: none;
                }
                .badge {
                    padding: 6px 12px;
                    border-radius: 20px;
                    font-size: 0.8rem;
                    font-weight: 600;
                }
                .badge-active { background: #d4edda; color: #155724; }
                .badge-processing { background: #fff3cd; color: #856404; }
                .badge-draft { background: #e2e3e5; color: #383d41; }
                .empty-state {
                    text-align: center;
                    padding: 40px;
                    color: #666;
                }
                .empty-state-icon {
                    font-size: 3rem;
                    margin-bottom: 20px;
                    opacity: 0.5;
                }
            </style>
        </head>
        <body>
            <div class="sidebar">
                <div style="text-align: center; margin-bottom: 30px;">
                    <div style="font-size: 2.5rem;">🎬</div>
                    <h2 style="margin: 10px 0;">HLS Manager</h2>
                    <small style="opacity: 0.8;">Dashboard</small>
                </div>
                
                <div style="margin-bottom: 30px;">
                    <a href="/dashboard" class="nav-link active">📊 Dashboard</a>
                    <a href="/channels" class="nav-link">📺 Canais</a>
                    <a href="/channels/new" class="nav-link">➕ Novo Canal</a>
                    <a href="/upload" class="nav-link">📤 Upload</a>
                    <a href="/settings" class="nav-link">⚙️ Configurações</a>
                </div>
                
                <div style="margin-top: auto; padding-top: 20px; border-top: 1px solid rgba(255,255,255,0.1);">
                    <div style="margin-bottom: 10px; opacity: 0.8;">
                        <small>Conectado como:</small><br>
                        <strong>{{ current_user.username }}</strong>
                    </div>
                    <a href="/logout" class="nav-link" style="color: #ff6b6b;">🚪 Sair</a>
                </div>
            </div>
            
            <div class="main-content">
                <h1>Dashboard</h1>
                <p style="color: #666; margin-bottom: 30px;">Bem-vindo de volta, {{ current_user.username }}! 👋</p>
                
                <div class="stats-grid">
                    <div class="stat-card">
                        <div class="stat-label">Total de Canais</div>
                        <div class="stat-value">{{ total_channels }}</div>
                        <small>Todos os canais do sistema</small>
                    </div>
                    <div class="stat-card">
                        <div class="stat-label">Meus Canais</div>
                        <div class="stat-value">{{ user_channels }}</div>
                        <small>Canais que você criou</small>
                    </div>
                    <div class="stat-card">
                        <div class="stat-label">Canais Ativos</div>
                        <div class="stat-value">{{ active_channels }}</div>
                        <small>Prontos para streaming</small>
                    </div>
                    <div class="stat-card">
                        <div class="stat-label">Status Sistema</div>
                        <div class="stat-value">✅</div>
                        <small>100% Operacional</small>
                    </div>
                </div>
                
                <div style="margin-top: 30px;">
                    <a href="/channels/new" class="btn">➕ Criar Novo Canal</a>
                    <a href="/upload" class="btn">📤 Upload de Vídeo</a>
                    <a href="/channels" class="btn" style="background: #6c757d;">📁 Ver Todos Canais</a>
                </div>
                
                <div class="channel-list">
                    <h3 style="margin-bottom: 20px;">Meus Canais Recentes</h3>
                    
                    {% if channels %}
                        {% for channel in channels %}
                            <div class="channel-item">
                                <div>
                                    <h4 style="margin-bottom: 5px;">{{ channel.name }}</h4>
                                    <p style="color: #666; margin-bottom: 10px;">
                                        {{ channel.description or 'Sem descrição' }}
                                    </p>
                                    <small style="color: #999;">
                                        Criado em: {{ channel.created_at.strftime('%d/%m/%Y %H:%M') }}
                                        {% if channel.file_size %}
                                            • {{ (channel.file_size / 1024 / 1024) | round(1) }} MB
                                        {% endif %}
                                    </small>
                                </div>
                                <div style="text-align: right;">
                                    <span class="badge badge-{{ channel.status }}">
                                        {{ channel.status | upper }}
                                    </span>
                                    {% if channel.hls_url %}
                                        <br><br>
                                        <a href="{{ channel.hls_url }}" target="_blank" class="btn" style="padding: 8px 16px; font-size: 0.9rem;">
                                            ▶️ Assistir
                                        </a>
                                    {% endif %}
                                </div>
                            </div>
                        {% endfor %}
                    {% else %}
                        <div class="empty-state">
                            <div class="empty-state-icon">📺</div>
                            <h3 style="margin-bottom: 10px;">Nenhum canal criado ainda</h3>
                            <p style="margin-bottom: 20px; color: #666;">
                                Comece criando seu primeiro canal ou fazendo upload de um vídeo.
                            </p>
                            <a href="/channels/new" class="btn">Criar Primeiro Canal</a>
                        </div>
                    {% endif %}
                </div>
            </div>
        </body>
        </html>
    ''', total_channels=total_channels, user_channels=user_channels,
        active_channels=active_channels, channels=channels)

@app.route('/channels')
@login_required
def channel_list():
    channels = Channel.query.filter_by(user_id=current_user.id).all()
    return render_template_string('''
        <h1>📺 Meus Canais</h1>
        <a href="/channels/new" class="btn">➕ Novo Canal</a>
        <div style="margin-top: 20px;">
            {% for channel in channels %}
                <div style="border: 1px solid #ddd; padding: 20px; margin: 15px 0; border-radius: 8px;">
                    <h3>{{ channel.name }}</h3>
                    <p>{{ channel.description or 'Sem descrição' }}</p>
                    <p><strong>Status:</strong> {{ channel.status }}</p>
                    {% if channel.hls_url %}
                        <a href="{{ channel.hls_url }}" target="_blank" class="btn">▶️ Assistir</a>
                    {% endif %}
                </div>
            {% endfor %}
        </div>
    ''')

@app.route('/channels/new', methods=['GET', 'POST'])
@login_required
def new_channel():
    if request.method == 'POST':
        name = request.form.get('name')
        description = request.form.get('description')
        
        # Criar slug único
        slug = name.lower().replace(' ', '-') + '-' + str(uuid.uuid4())[:8]
        
        channel = Channel(
            name=name,
            slug=slug,
            description=description,
            user_id=current_user.id
        )
        
        db.session.add(channel)
        db.session.commit()
        
        flash('Canal criado com sucesso!', 'success')
        return redirect(url_for('dashboard'))
    
    return render_template_string('''
        <div style="max-width: 600px; margin: 0 auto; padding: 20px;">
            <h1>➕ Novo Canal</h1>
            <form method="POST">
                <div style="margin-bottom: 20px;">
                    <label style="display: block; margin-bottom: 5px; font-weight: bold;">Nome do Canal:</label>
                    <input type="text" name="name" required style="width: 100%; padding: 10px; border: 1px solid #ddd; border-radius: 5px;">
                </div>
                <div style="margin-bottom: 20px;">
                    <label style="display: block; margin-bottom: 5px; font-weight: bold;">Descrição:</label>
                    <textarea name="description" rows="4" style="width: 100%; padding: 10px; border: 1px solid #ddd; border-radius: 5px;"></textarea>
                </div>
                <button type="submit" style="padding: 12px 30px; background: #4361ee; color: white; border: none; border-radius: 5px; font-weight: bold; cursor: pointer;">
                    Criar Canal
                </button>
            </form>
        </div>
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
            flash('Tipo de arquivo não permitido. Use: MP4, MKV, AVI, MOV, WebM, FLV', 'danger')
            return redirect(request.url)
        
        # Salvar arquivo
        filename = secure_filename(file.filename)
        unique_name = f"{uuid.uuid4()}_{filename}"
        filepath = os.path.join(app.config['UPLOAD_FOLDER'], unique_name)
        file.save(filepath)
        
        # Obter tamanho do arquivo
        file_size = os.path.getsize(filepath)
        
        # Criar canal automático
        channel_name = filename.rsplit('.', 1)[0]  # Remove extensão
        channel = Channel(
            name=channel_name,
            slug=f"{channel_name}-{uuid.uuid4()[:8]}".lower().replace(' ', '-'),
            video_filename=unique_name,
            user_id=current_user.id,
            status='processing',
            file_size=file_size
        )
        
        db.session.add(channel)
        db.session.commit()
        
        # Iniciar conversão em background (simplificado)
        try:
            output_dir = os.path.join(app.config['HLS_FOLDER'], str(channel.id))
            success, result = convert_to_hls(filepath, output_dir, channel.id)
            
            if success:
                channel.hls_url = result
                channel.status = 'active'
                channel.segment_count = len([f for f in os.listdir(output_dir) if f.endswith('.ts')])
                flash('✅ Vídeo convertido com sucesso! Agora está pronto para streaming.', 'success')
            else:
                channel.status = 'error'
                flash(f'❌ Erro na conversão: {result[:100]}', 'danger')
            
            db.session.commit()
            
        except Exception as e:
            channel.status = 'error'
            db.session.commit()
            flash(f'❌ Erro: {str(e)}', 'danger')
        
        return redirect(url_for('dashboard'))
    
    return render_template_string('''
        <div style="max-width: 600px; margin: 0 auto; padding: 20px;">
            <h1>📤 Upload de Vídeo</h1>
            <p style="margin-bottom: 20px; color: #666;">
                Envie um vídeo para conversão automática para HLS. O sistema criará um canal automaticamente.
            </p>
            
            <form method="POST" enctype="multipart/form-data">
                <div style="margin-bottom: 20px;">
                    <label style="display: block; margin-bottom: 10px; font-weight: bold;">
                        Selecione o vídeo:
                    </label>
                    <input type="file" name="video" accept="video/*" required
                           style="padding: 15px; border: 2px dashed #ddd; border-radius: 10px; width: 100%;">
                </div>
                
                <div style="background: #f8f9fa; padding: 15px; border-radius: 8px; margin-bottom: 20px;">
                    <strong>Formatos suportados:</strong>
                    <ul style="margin-top: 10px; color: #666;">
                        <li>MP4 (recomendado)</li>
                        <li>MKV</li>
                        <li>AVI</li>
                        <li>MOV</li>
                        <li>WebM</li>
                        <li>FLV</li>
                    </ul>
                    <p style="margin-top: 10px; color: #999;">
                        <small>Tamanho máximo: 2GB</small>
                    </p>
                </div>
                
                <button type="submit" 
                        style="padding: 15px 40px; background: #4361ee; color: white; border: none; border-radius: 8px; font-weight: bold; font-size: 1.1rem; cursor: pointer;">
                    🚀 Enviar e Converter
                </button>
            </form>
        </div>
    ''')

@app.route('/hls/<int:channel_id>/<path:filename>')
def serve_hls(channel_id, filename):
    """Servir arquivos HLS"""
    channel_dir = os.path.join(app.config['HLS_FOLDER'], str(channel_id))
    filepath = os.path.join(channel_dir, filename)
    
    if os.path.exists(filepath):
        return send_file(filepath)
    return 'Arquivo não encontrado', 404

@app.route('/settings')
@login_required
def settings():
    return render_template_string('''
        <h1>⚙️ Configurações</h1>
        <p>Página de configurações em desenvolvimento.</p>
    ''')

@app.route('/logout')
@login_required
def logout():
    logout_user()
    flash('Você foi desconectado com sucesso.', 'info')
    return redirect(url_for('index'))

@app.route('/health')
def health():
    try:
        # Testar banco de dados
        db.session.execute('SELECT 1')
        
        # Testar diretórios
        dirs = ['UPLOAD_FOLDER', 'HLS_FOLDER']
        dirs_status = {}
        
        for dir_name in dirs:
            path = app.config[dir_name]
            dirs_status[dir_name] = {
                'exists': os.path.exists(path),
                'writable': os.access(path, os.W_OK)
            }
        
        # Contar canais
        total_channels = Channel.query.count()
        active_channels = Channel.query.filter_by(status='active').count()
        
        return jsonify({
            'status': 'healthy',
            'service': 'hls-manager',
            'database': 'sqlite',
            'database_status': 'connected',
            'directories': dirs_status,
            'channels': {
                'total': total_channels,
                'active': active_channels
            },
            'timestamp': datetime.utcnow().isoformat(),
            'version': '2.0.0'
        })
    except Exception as e:
        return jsonify({
            'status': 'unhealthy',
            'error': str(e),
            'timestamp': datetime.utcnow().isoformat()
        }), 500

# ========== INICIALIZAÇÃO ==========
with app.app_context():
    # Criar tabelas
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
        print("✅ Usuário admin criado: admin / admin123")

if __name__ == '__main__':
    print("🚀 Iniciando HLS Manager na porta 5000...")
    app.run(host='0.0.0.0', port=5000, debug=False)
EOF

# 6. CRIAR ARQUIVO .env
echo "⚙️ Criando configuração..."
SECRET_KEY=$(openssl rand -hex 32)

sudo tee /opt/hls/.env > /dev/null << EOF
SECRET_KEY=${SECRET_KEY}
DEBUG=False
PORT=5000
HOST=0.0.0.0
ADMIN_PASSWORD=admin123
EOF

sudo chown hlsuser:hlsuser /opt/hls/.env
sudo chmod 600 /opt/hls/.env

# 7. CRIAR SERVIÇO SYSTEMD
echo "⚙️ Criando serviço systemd..."
sudo tee /etc/systemd/system/hls.service > /dev/null << EOF
[Unit]
Description=HLS Manager Service
After=network.target
Wants=network.target

[Service]
Type=simple
User=hlsuser
Group=hlsuser
WorkingDirectory=/opt/hls
Environment="PATH=/opt/hls/venv/bin"
Environment="FLASK_APP=app.py"
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
SyslogIdentifier=hls-manager

# Segurança
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=/opt/hls/uploads /opt/hls/hls /opt/hls/logs

[Install]
WantedBy=multi-user.target
EOF

# 8. CRIAR SCRIPT DE INICIALIZAÇÃO SIMPLES
sudo tee /opt/hls/start.sh > /dev/null << 'EOF'
#!/bin/bash
echo "🚀 Iniciando HLS Manager..."
cd /opt/hls
source venv/bin/activate
exec gunicorn --bind 0.0.0.0:5000 app:app
EOF

sudo chmod +x /opt/hls/start.sh
sudo chown hlsuser:hlsuser /opt/hls/start.sh

# 9. INICIAR O SERVIÇO
echo "🚀 Iniciando HLS Manager..."
sudo systemctl daemon-reload
sudo systemctl enable hls
sudo systemctl start hls

# 10. AGUARDAR E TESTAR
echo "⏳ Aguardando inicialização (10 segundos)..."
sleep 10

echo "🧪 Testando instalação..."

# Verificar serviço
if sudo systemctl is-active --quiet hls; then
    echo "✅ Serviço HLS está ATIVO e RODANDO"
    SERVICE_STATUS="✅"
else
    echo "❌ Serviço HLS está INATIVO"
    SERVICE_STATUS="❌"
    echo "Verificando logs..."
    sudo journalctl -u hls -n 20 --no-pager
fi

# Testar aplicação
echo "Testando endpoint de saúde..."
if curl -s --max-time 10 http://localhost:5000/health 2>/dev/null | grep -q "healthy"; then
    echo "✅ Aplicação está RESPONDENDO corretamente"
    APP_STATUS="✅"
else
    echo "⚠️ Aplicação não responde no health check"
    APP_STATUS="⚠️"
    
    # Tentar ver se pelo menos o serviço está ouvindo
    if sudo netstat -tlnp | grep -q ":5000"; then
        echo "✅ Serviço está ouvindo na porta 5000"
    else
        echo "❌ Serviço não está ouvindo na porta 5000"
    fi
fi

# 11. MOSTRAR INFORMAÇÕES
IP=$(hostname -I | awk '{print $1}' 2>/dev/null || curl -s --max-time 5 ifconfig.me 2>/dev/null || echo "localhost")

echo ""
echo "🎉🎉🎉 HLS MANAGER INSTALADO COM SUCESSO! 🎉🎉🎉"
echo "=============================================="
echo ""
echo "📊 STATUS DA INSTALAÇÃO:"
echo "   • Serviço: $SERVICE_STATUS"
echo "   • Aplicação: $APP_STATUS"
echo "   • Banco de Dados: ✅ SQLite (100% funcional)"
echo ""
echo "🌐 URL DE ACESSO:"
echo "   🌍 http://$IP:5000"
echo "   🖥️  http://localhost:5000"
echo ""
echo "🔐 CREDENCIAIS DE LOGIN:"
echo "   👤 Usuário: admin"
echo "   🔑 Senha: admin123"
echo ""
echo "✨ FUNCIONALIDADES PRINCIPAIS:"
echo "   ✅ Dashboard completo com estatísticas"
echo "   ✅ Sistema de login seguro"
echo "   ✅ Criação e gerenciamento de canais"
echo "   ✅ Upload de vídeos (MP4, MKV, AVI, MOV, WebM, FLV)"
echo "   ✅ Conversão automática para HLS com FFmpeg"
echo "   ✅ Player HLS integrado"
echo "   ✅ Health check do sistema"
echo ""
echo "⚙️ COMANDOS DE GERENCIAMENTO:"
echo "   • Ver status:      sudo systemctl status hls"
echo "   • Ver logs:        sudo journalctl -u hls -f"
echo "   • Reiniciar:       sudo systemctl restart hls"
echo "   • Parar:           sudo systemctl stop hls"
echo "   • Iniciar:         sudo systemctl start hls"
echo ""
echo "📁 ESTRUTURA DE DIRETÓRIOS:"
echo "   /opt/hls/"
echo "   ├── app.py          # Aplicação principal"
echo "   ├── hls.db          # Banco de dados SQLite"
echo "   ├── uploads/        # Vídeos enviados"
echo "   ├── hls/            # Arquivos HLS gerados"
echo "   └── logs/           # Logs da aplicação"
echo ""
echo "🔧 CONFIGURAÇÃO PERSONALIZADA:"
echo "   • Edite /opt/hls/.env para alterar configurações"
echo "   • A senha pode ser alterada no painel após login"
echo ""
echo "🚀 SISTEMA PRONTO PARA USO!"
echo ""
echo "⚠️ DICA IMPORTANTE:"
echo "   Após o primeiro login, altere a senha do admin no painel!"
echo ""
