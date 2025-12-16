#!/bin/bash
# install_hls_manager.sh - Sistema completo com painel de gerenciamento e MariaDB

set -e  # Sai imediatamente em caso de erro

echo "🎬 INSTALANDO HLS MANAGER COMPLETO"
echo "📊 Sistema com painel de gerenciamento + MariaDB"

# 1. Atualizar sistema
echo "📦 Atualizando sistema..."
sudo apt-get update
sudo apt-get upgrade -y

# 2. Instalar dependências
echo "📦 Instalando dependências..."
sudo apt-get install -y python3 python3-pip ffmpeg python3-venv libmagic1 nginx ufw mariadb-server mariadb-client libmariadb-dev python3-dev

# 3. Configurar MariaDB
echo "🗄️ Configurando MariaDB..."
sudo systemctl start mariadb
sudo systemctl enable mariadb

# Segurança do MariaDB (script automático)
echo "🔐 Executando configuração de segurança do MariaDB..."
sudo mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY 'TempRootPass123!';" 2>/dev/null || true

SECURE_MYSQL=$(expect -c "
set timeout 10
spawn sudo mysql_secure_installation
expect \"Enter current password for root (enter for none):\"
send \"TempRootPass123!\r\"
expect \"Switch to unix_socket authentication\"
send \"n\r\"
expect \"Change the root password?\"
send \"n\r\"
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

# 4. Criar banco de dados e usuário
echo "🗃️ Criando banco de dados..."
MYSQL_ROOT_PASS="HlsManagerRoot@2024"
MYSQL_APP_PASS="HlsAppSecure@2024"
MYSQL_APP_USER="hls_manager"

sudo mysql -u root <<-EOF
CREATE DATABASE IF NOT EXISTS hls_manager CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${MYSQL_APP_USER}'@'localhost' IDENTIFIED BY '${MYSQL_APP_PASS}';
GRANT ALL PRIVILEGES ON hls_manager.* TO '${MYSQL_APP_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF

# 5. Criar usuário dedicado
echo "👤 Criando usuário dedicado..."
if ! id "hlsmanager" &>/dev/null; then
    sudo useradd -r -s /bin/false -m -d /opt/hls-manager hlsmanager
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

# 10. Criar arquivo de configuração .env
echo "⚙️ Criando configuração..."
sudo tee /opt/hls-manager/config/.env > /dev/null << EOF
# Configurações do HLS Manager
DEBUG=False
PORT=5000
HOST=127.0.0.1
SECRET_KEY=

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
ADMIN_PASSWORD=

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

# 11. Gerar senha segura e chave secreta
echo "🔑 Gerando credenciais seguras..."
ADMIN_PASSWORD=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9!@#$%^&*' | head -c 16)
SECRET_KEY=$(openssl rand -hex 32)

echo "ADMIN_PASSWORD=$ADMIN_PASSWORD" | sudo tee -a /opt/hls-manager/config/.env > /dev/null
echo "SECRET_KEY=$SECRET_KEY" | sudo tee -a /opt/hls-manager/config/.env > /dev/null

sudo chown hlsmanager:hlsmanager /opt/hls-manager/config/.env
sudo chmod 640 /opt/hls-manager/config/.env

# 12. Criar aplicação Flask completa com painel
echo "💻 Criando aplicação Flask completa..."

# Estrutura de diretórios da aplicação
sudo -u hlsmanager mkdir -p /opt/hls-manager/app/{models,routes,templates,forms,utils,static/css,static/js,static/images}

# Arquivo principal da aplicação
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
    
    # Registrar blueprints
    from app.routes import main, auth, channels, api
    app.register_blueprint(main.bp)
    app.register_blueprint(auth.bp)
    app.register_blueprint(channels.bp)
    app.register_blueprint(api.bp)
    
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

# 13. Criar modelos do banco de dados
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
    
    # Relacionamentos
    channels = db.relationship('Channel', backref='owner', lazy='dynamic', cascade='all, delete-orphan')
    
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
    status = db.Column(db.Enum('draft', 'processing', 'active', 'error'), default='draft')
    hls_path = db.Column(db.String(512))
    thumbnail_path = db.Column(db.String(512))
    user_id = db.Column(db.Integer, db.ForeignKey('users.id'), nullable=False)
    
    # Metadados
    duration = db.Column(db.Integer)  # em segundos
    resolution = db.Column(db.String(32))
    file_size = db.Column(db.BigInteger)  # em bytes
    segment_count = db.Column(db.Integer)
    bitrate = db.Column(db.Integer)  # em kbps
    
    # Timestamps
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    updated_at = db.Column(db.DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)
    published_at = db.Column(db.DateTime)
    
    # Configurações HLS
    segment_time = db.Column(db.Integer, default=10)
    encryption_enabled = db.Column(db.Boolean, default=False)
    
    # Relacionamentos
    files = db.relationship('ChannelFile', backref='channel', lazy='dynamic', cascade='all, delete-orphan')
    logs = db.relationship('ChannelLog', backref='channel', lazy='dynamic', cascade='all, delete-orphan')
    
    def __repr__(self):
        return f'<Channel {self.name}>'
    
    @property
    def hls_url(self):
        if self.hls_path:
            return f"/hls/{self.slug}/index.m3u8"
        return None
    
    @property
    def is_playable(self):
        return self.status == 'active' and self.hls_path is not None

class ChannelFile(db.Model):
    __tablename__ = 'channel_files'
    
    id = db.Column(db.Integer, primary_key=True)
    channel_id = db.Column(db.Integer, db.ForeignKey('channels.id'), nullable=False)
    filename = db.Column(db.String(256), nullable=False)
    original_filename = db.Column(db.String(256), nullable=False)
    file_path = db.Column(db.String(512), nullable=False)
    file_size = db.Column(db.BigInteger)
    duration = db.Column(db.Integer)
    resolution = db.Column(db.String(32))
    bitrate = db.Column(db.Integer)
    format = db.Column(db.String(32))
    uploaded_at = db.Column(db.DateTime, default=datetime.utcnow)
    processed = db.Column(db.Boolean, default=False)
    
    def __repr__(self):
        return f'<ChannelFile {self.filename}>'

class ChannelLog(db.Model):
    __tablename__ = 'channel_logs'
    
    id = db.Column(db.Integer, primary_key=True)
    channel_id = db.Column(db.Integer, db.ForeignKey('channels.id'), nullable=False)
    level = db.Column(db.Enum('info', 'warning', 'error'))
    message = db.Column(db.Text, nullable=False)
    details = db.Column(db.Text)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    
    def __repr__(self):
        return f'<ChannelLog {self.level}: {self.message[:50]}>'

class SystemLog(db.Model):
    __tablename__ = 'system_logs'
    
    id = db.Column(db.Integer, primary_key=True)
    module = db.Column(db.String(64))
    level = db.Column(db.Enum('debug', 'info', 'warning', 'error', 'critical'))
    message = db.Column(db.Text, nullable=False)
    user_id = db.Column(db.Integer, db.ForeignKey('users.id'))
    ip_address = db.Column(db.String(45))
    user_agent = db.Column(db.Text)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    
    def __repr__(self):
        return f'<SystemLog {self.module}: {self.message[:50]}>'
EOF

# 14. Criar formulários
sudo tee /opt/hls-manager/app/forms/__init__.py > /dev/null << 'EOF'
from flask_wtf import FlaskForm
from flask_wtf.file import FileField, FileRequired, FileAllowed
from wtforms import StringField, TextAreaField, PasswordField, BooleanField, SelectField, IntegerField
from wtforms.validators import DataRequired, Email, Length, EqualTo, ValidationError
from app.models import User, Channel
import re

class LoginForm(FlaskForm):
    username = StringField('Usuário', validators=[DataRequired(), Length(min=3, max=64)])
    password = PasswordField('Senha', validators=[DataRequired()])
    remember = BooleanField('Lembrar-me')

class ChannelForm(FlaskForm):
    name = StringField('Nome do Canal', validators=[DataRequired(), Length(min=3, max=128)])
    description = TextAreaField('Descrição')
    segment_time = IntegerField('Duração do Segmento (segundos)', default=10)
    encryption_enabled = BooleanField('Habilitar Criptografia')

class UploadForm(FlaskForm):
    files = FileField('Arquivos de Vídeo', validators=[
        FileRequired(),
        FileAllowed(['mp4', 'mkv', 'avi', 'mov', 'webm', 'mpeg', 'mpg', 'flv'], 
                   'Apenas arquivos de vídeo são permitidos!')
    ], render_kw={'multiple': True})

class EditChannelForm(FlaskForm):
    name = StringField('Nome do Canal', validators=[DataRequired(), Length(min=3, max=128)])
    description = TextAreaField('Descrição')
    status = SelectField('Status', choices=[
        ('draft', 'Rascunho'),
        ('active', 'Ativo'),
        ('paused', 'Pausado')
    ])

class UserForm(FlaskForm):
    username = StringField('Usuário', validators=[DataRequired(), Length(min=3, max=64)])
    email = StringField('Email', validators=[DataRequired(), Email()])
    password = PasswordField('Senha', validators=[
        DataRequired(),
        Length(min=8, message='A senha deve ter pelo menos 8 caracteres'),
        EqualTo('confirm_password', message='As senhas devem coincidir')
    ])
    confirm_password = PasswordField('Confirmar Senha')
    is_admin = BooleanField('Administrador')
    
    def validate_username(self, field):
        if User.query.filter_by(username=field.data).first():
            raise ValidationError('Este nome de usuário já está em uso.')
    
    def validate_email(self, field):
        if User.query.filter_by(email=field.data).first():
            raise ValidationError('Este email já está em uso.')
    
    def validate_password(self, field):
        password = field.data
        if len(password) < 8:
            raise ValidationError('A senha deve ter pelo menos 8 caracteres.')
        if not re.search(r'[A-Z]', password):
            raise ValidationError('A senha deve conter pelo menos uma letra maiúscula.')
        if not re.search(r'[a-z]', password):
            raise ValidationError('A senha deve conter pelo menos uma letra minúscula.')
        if not re.search(r'\d', password):
            raise ValidationError('A senha deve conter pelo menos um número.')

class ChangePasswordForm(FlaskForm):
    current_password = PasswordField('Senha Atual', validators=[DataRequired()])
    new_password = PasswordField('Nova Senha', validators=[
        DataRequired(),
        Length(min=8, message='A nova senha deve ter pelo menos 8 caracteres'),
        EqualTo('confirm_password', message='As senhas devem coincidir')
    ])
    confirm_password = PasswordField('Confirmar Nova Senha')
EOF

# 15. Criar utilitários
sudo tee /opt/hls-manager/app/utils/__init__.py > /dev/null << 'EOF'
import os
import uuid
import magic
import subprocess
import threading
from datetime import datetime
from pathlib import Path
from flask import current_app
import logging

logger = logging.getLogger(__name__)

class HLSConverter:
    def __init__(self, channel_id):
        self.channel_id = channel_id
        self.base_dir = Path('/opt/hls-manager')
        self.hls_dir = self.base_dir / 'hls'
        self.temp_dir = self.base_dir / 'temp'
        self.logs_dir = self.base_dir / 'logs'
        
    def convert_to_hls(self, video_files, segment_time=10):
        """Converte arquivos de vídeo para HLS"""
        try:
            channel_slug = f"channel_{self.channel_id}_{uuid.uuid4().hex[:8]}"
            output_dir = self.hls_dir / channel_slug
            output_dir.mkdir(parents=True, exist_ok=True)
            
            m3u8_path = output_dir / 'index.m3u8'
            
            if len(video_files) == 1:
                # Arquivo único
                cmd = [
                    'ffmpeg', '-i', str(video_files[0]),
                    '-c:v', 'libx264', '-preset', 'medium', '-crf', '23',
                    '-c:a', 'aac', '-b:a', '128k',
                    '-hls_time', str(segment_time),
                    '-hls_list_size', '0',
                    '-hls_segment_filename', str(output_dir / 'segment_%03d.ts'),
                    '-f', 'hls', str(m3u8_path)
                ]
            else:
                # Múltiplos arquivos - concatenar
                concat_list = self.temp_dir / f"concat_{channel_slug}.txt"
                with open(concat_list, 'w') as f:
                    for video_path in video_files:
                        f.write(f"file '{video_path}'\n")
                
                cmd = [
                    'ffmpeg', '-f', 'concat', '-safe', '0',
                    '-i', str(concat_list),
                    '-c:v', 'libx264', '-preset', 'medium', '-crf', '23',
                    '-c:a', 'aac', '-b:a', '128k',
                    '-hls_time', str(segment_time),
                    '-hls_list_size', '0',
                    '-hls_segment_filename', str(output_dir / 'segment_%03d.ts'),
                    '-f', 'hls', str(m3u8_path)
                ]
            
            # Executar conversão
            logger.info(f"Iniciando conversão HLS para canal {self.channel_id}")
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=7200)
            
            if result.returncode != 0:
                logger.error(f"Erro na conversão HLS: {result.stderr}")
                return None
            
            # Coletar estatísticas
            segments = list(output_dir.glob('segment_*.ts'))
            stats = {
                'segment_count': len(segments),
                'hls_path': str(output_dir.relative_to(self.base_dir))
            }
            
            return stats
            
        except Exception as e:
            logger.error(f"Erro no conversor HLS: {str(e)}")
            return None
    
    def get_video_info(self, filepath):
        """Obtém informações do vídeo usando ffprobe"""
        try:
            cmd = [
                'ffprobe', '-v', 'error',
                '-select_streams', 'v:0',
                '-show_entries', 'stream=width,height,duration,bit_rate,codec_name',
                '-of', 'json',
                str(filepath)
            ]
            
            result = subprocess.run(cmd, capture_output=True, text=True)
            if result.returncode == 0:
                import json
                info = json.loads(result.stdout)
                if 'streams' in info and len(info['streams']) > 0:
                    stream = info['streams'][0]
                    return {
                        'width': stream.get('width'),
                        'height': stream.get('height'),
                        'duration': float(stream.get('duration', 0)),
                        'bitrate': int(stream.get('bit_rate', 0)) // 1000 if stream.get('bit_rate') else None,
                        'codec': stream.get('codec_name')
                    }
        except Exception as e:
            logger.error(f"Erro ao obter info do vídeo: {e}")
        
        return {}

def allowed_file(filename):
    """Verifica se a extensão do arquivo é permitida"""
    allowed_extensions = {'mp4', 'mkv', 'avi', 'mov', 'webm', 'mpeg', 'mpg', 'flv'}
    return '.' in filename and filename.rsplit('.', 1)[1].lower() in allowed_extensions

def is_valid_video(filepath):
    """Verifica se o arquivo é realmente um vídeo válido"""
    try:
        mime = magic.from_file(str(filepath), mime=True)
        return mime.startswith('video/')
    except:
        return False

def generate_slug(name):
    """Gera um slug a partir do nome"""
    import re
    slug = name.lower()
    slug = re.sub(r'[^a-z0-9]+', '-', slug)
    slug = re.sub(r'^-|-$', '', slug)
    return slug

def format_duration(seconds):
    """Formata duração em segundos para HH:MM:SS"""
    if not seconds:
        return "00:00"
    hours = int(seconds // 3600)
    minutes = int((seconds % 3600) // 60)
    secs = int(seconds % 60)
    if hours > 0:
        return f"{hours:02d}:{minutes:02d}:{secs:02d}"
    else:
        return f"{minutes:02d}:{secs:02d}"
EOF

# 16. Criar rotas principais
sudo mkdir -p /opt/hls-manager/app/routes
sudo tee /opt/hls-manager/app/routes/main.py > /dev/null << 'EOF'
from flask import Blueprint, render_template, request, jsonify, current_app
from flask_login import login_required, current_user
from app.models import Channel, SystemLog
from app import db

bp = Blueprint('main', __name__)

@bp.route('/')
@login_required
def index():
    """Dashboard principal"""
    # Estatísticas
    total_channels = Channel.query.count()
    active_channels = Channel.query.filter_by(status='active').count()
    processing_channels = Channel.query.filter_by(status='processing').count()
    
    # Canais recentes
    recent_channels = Channel.query.order_by(Channel.created_at.desc()).limit(10).all()
    
    # Logs recentes
    recent_logs = SystemLog.query.order_by(SystemLog.created_at.desc()).limit(20).all()
    
    return render_template('dashboard/index.html',
                         total_channels=total_channels,
                         active_channels=active_channels,
                         processing_channels=processing_channels,
                         recent_channels=recent_channels,
                         recent_logs=recent_logs)

@bp.route('/dashboard/stats')
@login_required
def dashboard_stats():
    """Retorna estatísticas do dashboard via AJAX"""
    from datetime import datetime, timedelta
    
    # Canais por status
    channels_by_status = {
        'draft': Channel.query.filter_by(status='draft').count(),
        'processing': Channel.query.filter_by(status='processing').count(),
        'active': Channel.query.filter_by(status='active').count(),
        'error': Channel.query.filter_by(status='error').count()
    }
    
    # Canais criados nos últimos 7 dias
    seven_days_ago = datetime.utcnow() - timedelta(days=7)
    recent_channels = Channel.query.filter(Channel.created_at >= seven_days_ago).count()
    
    # Tamanho total dos arquivos
    total_size = db.session.query(db.func.sum(Channel.file_size)).scalar() or 0
    
    return jsonify({
        'success': True,
        'channels_by_status': channels_by_status,
        'recent_channels': recent_channels,
        'total_size': total_size
    })
EOF

# 17. Criar rotas de autenticação
sudo tee /opt/hls-manager/app/routes/auth.py > /dev/null << 'EOF'
from flask import Blueprint, render_template, redirect, url_for, flash, request, jsonify
from flask_login import login_user, logout_user, login_required, current_user
from app.forms import LoginForm, ChangePasswordForm
from app.models import User, SystemLog
from app import db, login_manager
from datetime import datetime

bp = Blueprint('auth', __name__)

@login_manager.user_loader
def load_user(user_id):
    return User.query.get(int(user_id))

@bp.route('/login', methods=['GET', 'POST'])
def login():
    if current_user.is_authenticated:
        return redirect(url_for('main.index'))
    
    form = LoginForm()
    if form.validate_on_submit():
        user = User.query.filter_by(username=form.username.data).first()
        
        if user and user.check_password(form.password.data) and user.is_active:
            login_user(user, remember=form.remember.data)
            user.last_login = datetime.utcnow()
            db.session.commit()
            
            # Log
            log = SystemLog(
                module='auth',
                level='info',
                message=f'Login realizado por {user.username}',
                user_id=user.id,
                ip_address=request.remote_addr
            )
            db.session.add(log)
            db.session.commit()
            
            flash('Login realizado com sucesso!', 'success')
            next_page = request.args.get('next')
            return redirect(next_page or url_for('main.index'))
        else:
            flash('Usuário ou senha inválidos.', 'danger')
    
    return render_template('auth/login.html', form=form)

@bp.route('/logout')
@login_required
def logout():
    # Log
    log = SystemLog(
        module='auth',
        level='info',
        message=f'Logout realizado por {current_user.username}',
        user_id=current_user.id,
        ip_address=request.remote_addr
    )
    db.session.add(log)
    db.session.commit()
    
    logout_user()
    flash('Você foi desconectado.', 'info')
    return redirect(url_for('auth.login'))

@bp.route('/profile', methods=['GET', 'POST'])
@login_required
def profile():
    form = ChangePasswordForm()
    
    if form.validate_on_submit():
        if current_user.check_password(form.current_password.data):
            current_user.set_password(form.new_password.data)
            db.session.commit()
            
            # Log
            log = SystemLog(
                module='auth',
                level='info',
                message='Senha alterada com sucesso',
                user_id=current_user.id,
                ip_address=request.remote_addr
            )
            db.session.add(log)
            db.session.commit()
            
            flash('Senha alterada com sucesso!', 'success')
            return redirect(url_for('main.index'))
        else:
            flash('Senha atual incorreta.', 'danger')
    
    return render_template('auth/profile.html', form=form)
EOF

# 18. Criar rotas de canais
sudo tee /opt/hls-manager/app/routes/channels.py > /dev/null << 'EOF'
from flask import Blueprint, render_template, request, jsonify, flash, redirect, url_for, current_app
from flask_login import login_required, current_user
from werkzeug.utils import secure_filename
import os
import uuid
from datetime import datetime
from pathlib import Path

from app.forms import ChannelForm, UploadForm, EditChannelForm
from app.models import Channel, ChannelFile, ChannelLog, SystemLog
from app.utils import HLSConverter, allowed_file, is_valid_video, generate_slug
from app import db
import threading

bp = Blueprint('channels', __name__, url_prefix='/channels')

def process_channel_background(channel_id, file_paths):
    """Processa o canal em background"""
    with current_app.app_context():
        try:
            channel = Channel.query.get(channel_id)
            if not channel:
                return
            
            channel.status = 'processing'
            db.session.commit()
            
            # Converter para HLS
            converter = HLSConverter(channel_id)
            result = converter.convert_to_hls(file_paths, channel.segment_time)
            
            if result:
                channel.hls_path = result['hls_path']
                channel.segment_count = result['segment_count']
                channel.status = 'active'
                channel.published_at = datetime.utcnow()
                
                # Log
                log = ChannelLog(
                    channel_id=channel.id,
                    level='info',
                    message='Canal processado com sucesso',
                    details=f'Segmentos: {result["segment_count"]}'
                )
                db.session.add(log)
                
                flash(f'Canal "{channel.name}" processado com sucesso!', 'success')
            else:
                channel.status = 'error'
                log = ChannelLog(
                    channel_id=channel.id,
                    level='error',
                    message='Erro ao processar canal'
                )
                db.session.add(log)
                flash(f'Erro ao processar canal "{channel.name}"', 'danger')
            
            db.session.commit()
            
        except Exception as e:
            current_app.logger.error(f"Erro no processamento em background: {str(e)}")

@bp.route('/')
@login_required
def list_channels():
    """Lista todos os canais"""
    page = request.args.get('page', 1, type=int)
    status = request.args.get('status', 'all')
    
    query = Channel.query.filter_by(user_id=current_user.id)
    
    if status != 'all':
        query = query.filter_by(status=status)
    
    channels = query.order_by(Channel.created_at.desc()).paginate(
        page=page, per_page=20, error_out=False
    )
    
    return render_template('channels/list.html', 
                         channels=channels,
                         current_status=status)

@bp.route('/create', methods=['GET', 'POST'])
@login_required
def create_channel():
    """Cria um novo canal"""
    form = ChannelForm()
    
    if form.validate_on_submit():
        channel = Channel(
            name=form.name.data,
            slug=generate_slug(form.name.data),
            description=form.description.data,
            segment_time=form.segment_time.data,
            encryption_enabled=form.encryption_enabled.data,
            user_id=current_user.id
        )
        
        db.session.add(channel)
        db.session.commit()
        
        # Log
        log = SystemLog(
            module='channels',
            level='info',
            message=f'Canal criado: {channel.name}',
            user_id=current_user.id,
            ip_address=request.remote_addr
        )
        db.session.add(log)
        db.session.commit()
        
        flash(f'Canal "{channel.name}" criado com sucesso!', 'success')
        return redirect(url_for('channels.upload_files', channel_id=channel.id))
    
    return render_template('channels/create.html', form=form)

@bp.route('/<int:channel_id>/upload', methods=['GET', 'POST'])
@login_required
def upload_files(channel_id):
    """Upload de arquivos para o canal"""
    channel = Channel.query.get_or_404(channel_id)
    
    # Verificar permissão
    if channel.user_id != current_user.id and not current_user.is_admin:
        flash('Acesso negado.', 'danger')
        return redirect(url_for('channels.list_channels'))
    
    form = UploadForm()
    
    if form.validate_on_submit():
        try:
            uploaded_files = request.files.getlist('files')
            saved_files = []
            
            for file in uploaded_files:
                if file and allowed_file(file.filename):
                    filename = secure_filename(file.filename)
                    unique_filename = f"{uuid.uuid4().hex}_{filename}"
                    
                    # Salvar arquivo
                    upload_dir = Path('/opt/hls-manager/uploads') / str(channel_id)
                    upload_dir.mkdir(parents=True, exist_ok=True)
                    
                    file_path = upload_dir / unique_filename
                    file.save(str(file_path))
                    
                    # Validar se é vídeo
                    if not is_valid_video(file_path):
                        file_path.unlink()
                        flash(f'Arquivo "{filename}" não é um vídeo válido.', 'warning')
                        continue
                    
                    # Criar registro no banco
                    channel_file = ChannelFile(
                        channel_id=channel.id,
                        filename=unique_filename,
                        original_filename=filename,
                        file_path=str(file_path)
                    )
                    
                    db.session.add(channel_file)
                    saved_files.append(file_path)
            
            if saved_files:
                db.session.commit()
                flash(f'{len(saved_files)} arquivo(s) enviado(s) com sucesso!', 'success')
                
                # Iniciar processamento em background
                thread = threading.Thread(
                    target=process_channel_background,
                    args=(channel.id, saved_files)
                )
                thread.daemon = True
                thread.start()
                
                return redirect(url_for('channels.channel_detail', channel_id=channel.id))
            else:
                flash('Nenhum arquivo válido foi enviado.', 'warning')
                
        except Exception as e:
            current_app.logger.error(f"Erro no upload: {str(e)}")
            flash('Erro ao enviar arquivos.', 'danger')
    
    return render_template('channels/upload.html', form=form, channel=channel)

@bp.route('/<int:channel_id>')
@login_required
def channel_detail(channel_id):
    """Detalhes do canal"""
    channel = Channel.query.get_or_404(channel_id)
    
    # Verificar permissão
    if channel.user_id != current_user.id and not current_user.is_admin:
        flash('Acesso negado.', 'danger')
        return redirect(url_for('channels.list_channels'))
    
    files = channel.files.order_by(ChannelFile.uploaded_at.desc()).all()
    logs = channel.logs.order_by(ChannelLog.created_at.desc()).limit(50).all()
    
    return render_template('channels/detail.html',
                         channel=channel,
                         files=files,
                         logs=logs)

@bp.route('/<int:channel_id>/edit', methods=['GET', 'POST'])
@login_required
def edit_channel(channel_id):
    """Edita um canal existente"""
    channel = Channel.query.get_or_404(channel_id)
    
    # Verificar permissão
    if channel.user_id != current_user.id and not current_user.is_admin:
        flash('Acesso negado.', 'danger')
        return redirect(url_for('channels.list_channels'))
    
    form = EditChannelForm(obj=channel)
    
    if form.validate_on_submit():
        channel.name = form.name.data
        channel.description = form.description.data
        channel.status = form.status.data
        channel.updated_at = datetime.utcnow()
        
        db.session.commit()
        
        # Log
        log = SystemLog(
            module='channels',
            level='info',
            message=f'Canal editado: {channel.name}',
            user_id=current_user.id,
            ip_address=request.remote_addr
        )
        db.session.add(log)
        db.session.commit()
        
        flash(f'Canal "{channel.name}" atualizado com sucesso!', 'success')
        return redirect(url_for('channels.channel_detail', channel_id=channel.id))
    
    return render_template('channels/edit.html', form=form, channel=channel)

@bp.route('/<int:channel_id>/delete', methods=['POST'])
@login_required
def delete_channel(channel_id):
    """Exclui um canal"""
    channel = Channel.query.get_or_404(channel_id)
    
    # Verificar permissão
    if channel.user_id != current_user.id and not current_user.is_admin:
        return jsonify({'success': False, 'error': 'Acesso negado'}), 403
    
    try:
        # Remover arquivos físicos
        if channel.hls_path:
            import shutil
            hls_dir = Path('/opt/hls-manager') / channel.hls_path
            if hls_dir.exists():
                shutil.rmtree(hls_dir)
        
        # Remover arquivos de upload
        upload_dir = Path('/opt/hls-manager/uploads') / str(channel_id)
        if upload_dir.exists():
            shutil.rmtree(upload_dir)
        
        # Log antes de excluir
        log = SystemLog(
            module='channels',
            level='info',
            message=f'Canal excluído: {channel.name}',
            user_id=current_user.id,
            ip_address=request.remote_addr
        )
        db.session.add(log)
        
        # Excluir do banco (cascade irá excluir arquivos e logs relacionados)
        db.session.delete(channel)
        db.session.commit()
        
        return jsonify({
            'success': True,
            'message': f'Canal "{channel.name}" excluído com sucesso!'
        })
        
    except Exception as e:
        current_app.logger.error(f"Erro ao excluir canal: {str(e)}")
        return jsonify({
            'success': False,
            'error': 'Erro ao excluir canal'
        }), 500

@bp.route('/<int:channel_id>/play')
@login_required
def play_channel(channel_id):
    """Player do canal"""
    channel = Channel.query.get_or_404(channel_id)
    
    # Verificar permissão
    if channel.user_id != current_user.id and not current_user.is_admin:
        flash('Acesso negado.', 'danger')
        return redirect(url_for('channels.list_channels'))
    
    if not channel.is_playable:
        flash('Este canal não está disponível para reprodução.', 'warning')
        return redirect(url_for('channels.channel_detail', channel_id=channel.id))
    
    return render_template('channels/play.html', channel=channel)

@bp.route('/<int:channel_id>/reprocess', methods=['POST'])
@login_required
def reprocess_channel(channel_id):
    """Reprocessa o canal"""
    channel = Channel.query.get_or_404(channel_id)
    
    # Verificar permissão
    if channel.user_id != current_user.id and not current_user.is_admin:
        return jsonify({'success': False, 'error': 'Acesso negado'}), 403
    
    try:
        # Coletar arquivos originais
        file_paths = []
        for channel_file in channel.files.all():
            if Path(channel_file.file_path).exists():
                file_paths.append(Path(channel_file.file_path))
        
        if not file_paths:
            return jsonify({
                'success': False,
                'error': 'Nenhum arquivo original encontrado'
            }), 400
        
        # Iniciar reprocessamento em background
        thread = threading.Thread(
            target=process_channel_background,
            args=(channel.id, file_paths)
        )
        thread.daemon = True
        thread.start()
        
        return jsonify({
            'success': True,
            'message': 'Reprocessamento iniciado em background'
        })
        
    except Exception as e:
        current_app.logger.error(f"Erro ao reprocessar canal: {str(e)}")
        return jsonify({
            'success': False,
            'error': 'Erro ao reprocessar canal'
        }), 500
EOF

# 19. Criar rotas API
sudo tee /opt/hls-manager/app/routes/api.py > /dev/null << 'EOF'
from flask import Blueprint, jsonify, request
from flask_login import login_required, current_user
from app.models import Channel, ChannelLog
from app import db

bp = Blueprint('api', __name__, url_prefix='/api')

@bp.route('/channels')
@login_required
def get_channels():
    """API para listar canais"""
    page = request.args.get('page', 1, type=int)
    per_page = request.args.get('per_page', 20, type=int)
    status = request.args.get('status')
    
    query = Channel.query.filter_by(user_id=current_user.id)
    
    if status:
        query = query.filter_by(status=status)
    
    channels = query.order_by(Channel.created_at.desc()).paginate(
        page=page, per_page=per_page, error_out=False
    )
    
    return jsonify({
        'success': True,
        'channels': [{
            'id': c.id,
            'name': c.name,
            'slug': c.slug,
            'status': c.status,
            'hls_url': c.hls_url,
            'duration': c.duration,
            'resolution': c.resolution,
            'created_at': c.created_at.isoformat(),
            'updated_at': c.updated_at.isoformat()
        } for c in channels.items],
        'total': channels.total,
        'pages': channels.pages,
        'current_page': channels.page
    })

@bp.route('/channels/<int:channel_id>')
@login_required
def get_channel(channel_id):
    """API para obter detalhes de um canal"""
    channel = Channel.query.get_or_404(channel_id)
    
    if channel.user_id != current_user.id and not current_user.is_admin:
        return jsonify({'success': False, 'error': 'Acesso negado'}), 403
    
    files = [{
        'id': f.id,
        'filename': f.original_filename,
        'size': f.file_size,
        'uploaded_at': f.uploaded_at.isoformat()
    } for f in channel.files.all()]
    
    logs = [{
        'id': l.id,
        'level': l.level,
        'message': l.message,
        'details': l.details,
        'created_at': l.created_at.isoformat()
    } for l in channel.logs.order_by(ChannelLog.created_at.desc()).limit(100).all()]
    
    return jsonify({
        'success': True,
        'channel': {
            'id': channel.id,
            'name': channel.name,
            'description': channel.description,
            'status': channel.status,
            'hls_url': channel.hls_url,
            'segment_count': channel.segment_count,
            'bitrate': channel.bitrate,
            'duration': channel.duration,
            'resolution': channel.resolution,
            'created_at': channel.created_at.isoformat(),
            'updated_at': channel.updated_at.isoformat(),
            'files': files,
            'logs': logs
        }
    })

@bp.route('/channels/<int:channel_id>/status')
@login_required
def get_channel_status(channel_id):
    """API para obter status de processamento do canal"""
    channel = Channel.query.get_or_404(channel_id)
    
    if channel.user_id != current_user.id and not current_user.is_admin:
        return jsonify({'success': False, 'error': 'Acesso negado'}), 403
    
    return jsonify({
        'success': True,
        'status': channel.status,
        'progress': channel.progress if hasattr(channel, 'progress') else None,
        'last_update': channel.updated_at.isoformat()
    })

@bp.route('/system/stats')
@login_required
def system_stats():
    """API para estatísticas do sistema"""
    from datetime import datetime, timedelta
    import psutil
    import shutil
    
    # Estatísticas de canais
    total_channels = Channel.query.count()
    active_channels = Channel.query.filter_by(status='active').count()
    
    # Canais por status
    channels_by_status = {
        'draft': Channel.query.filter_by(status='draft').count(),
        'processing': Channel.query.filter_by(status='processing').count(),
        'active': Channel.query.filter_by(status='active').count(),
        'error': Channel.query.filter_by(status='error').count()
    }
    
    # Estatísticas de disco
    total, used, free = shutil.disk_usage('/opt/hls-manager/hls')
    
    # Estatísticas de sistema
    cpu_percent = psutil.cpu_percent(interval=1)
    memory = psutil.virtual_memory()
    
    return jsonify({
        'success': True,
        'stats': {
            'channels': {
                'total': total_channels,
                'active': active_channels,
                'by_status': channels_by_status
            },
            'disk': {
                'total': total,
                'used': used,
                'free': free,
                'percent': (used / total) * 100 if total > 0 else 0
            },
            'system': {
                'cpu_percent': cpu_percent,
                'memory_percent': memory.percent,
                'memory_used': memory.used,
                'memory_total': memory.total
            },
            'timestamp': datetime.utcnow().isoformat()
        }
    })
EOF

# 20. Criar arquivo principal da aplicação
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
from app.models import User, Channel, ChannelFile, ChannelLog, SystemLog
from flask_migrate import Migrate

app = create_app()
migrate = Migrate(app, db)

@app.shell_context_processor
def make_shell_context():
    return {
        'db': db,
        'User': User,
        'Channel': Channel,
        'ChannelFile': ChannelFile,
        'ChannelLog': ChannelLog,
        'SystemLog': SystemLog
    }

def init_db():
    """Inicializa o banco de dados e cria usuário admin"""
    with app.app_context():
        # Criar tabelas
        db.create_all()
        
        # Criar usuário admin se não existir
        admin_user = User.query.filter_by(username='admin').first()
        if not admin_user:
            from werkzeug.security import generate_password_hash
            import os
            
            admin_pass = os.getenv('ADMIN_PASSWORD', 'admin123')
            admin_user = User(
                username='admin',
                email='admin@localhost',
                password_hash=generate_password_hash(admin_pass),
                is_admin=True,
                is_active=True
            )
            db.session.add(admin_user)
            db.session.commit()
            print(f"✅ Usuário admin criado com senha: {admin_pass}")
        
        print("✅ Banco de dados inicializado com sucesso!")

if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == 'initdb':
        init_db()
    else:
        # Verificar e inicializar banco de dados
        with app.app_context():
            try:
                db.session.execute('SELECT 1')
                print("✅ Conexão com banco de dados estabelecida")
            except:
                print("⚠️ Banco de dados não encontrado. Executando inicialização...")
                init_db()
        
        print(f"🚀 Iniciando HLS Manager na porta {app.config.get('PORT', 5000)}")
        app.run(
            host=app.config.get('HOST', '127.0.0.1'),
            port=app.config.get('PORT', 5000),
            debug=app.config.get('DEBUG', False)
        )
EOF

sudo chmod +x /opt/hls-manager/run.py

# 21. Criar templates HTML básicos
echo "🎨 Criando templates HTML..."
sudo mkdir -p /opt/hls-manager/app/templates/{layout,auth,channels,dashboard,errors}

# Layout base
sudo tee /opt/hls-manager/app/templates/layout/base.html > /dev/null << 'EOF'
<!DOCTYPE html>
<html lang="pt-BR">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>{% block title %}HLS Manager{% endblock %}</title>
    
    <!-- Bootstrap 5 -->
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.1.3/dist/css/bootstrap.min.css" rel="stylesheet">
    <!-- Bootstrap Icons -->
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap-icons@1.8.1/font/bootstrap-icons.css">
    <!-- DataTables -->
    <link rel="stylesheet" type="text/css" href="https://cdn.datatables.net/1.11.5/css/dataTables.bootstrap5.min.css">
    
    <style>
        :root {
            --primary-color: #4361ee;
            --secondary-color: #3a0ca3;
            --success-color: #4cc9f0;
            --danger-color: #f72585;
            --warning-color: #f8961e;
            --light-color: #f8f9fa;
            --dark-color: #212529;
        }
        
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            background-color: #f5f7fb;
            color: #333;
        }
        
        .sidebar {
            background: linear-gradient(180deg, var(--primary-color) 0%, var(--secondary-color) 100%);
            color: white;
            min-height: 100vh;
            box-shadow: 3px 0 10px rgba(0,0,0,0.1);
        }
        
        .sidebar .nav-link {
            color: rgba(255,255,255,0.8);
            padding: 12px 20px;
            margin: 5px 0;
            border-radius: 8px;
            transition: all 0.3s ease;
        }
        
        .sidebar .nav-link:hover {
            background: rgba(255,255,255,0.1);
            color: white;
        }
        
        .sidebar .nav-link.active {
            background: rgba(255,255,255,0.2);
            color: white;
            font-weight: 600;
        }
        
        .sidebar .nav-link i {
            width: 24px;
            text-align: center;
            margin-right: 10px;
        }
        
        .main-content {
            padding: 20px;
        }
        
        .card {
            border: none;
            border-radius: 12px;
            box-shadow: 0 4px 6px rgba(0,0,0,0.05);
            transition: transform 0.3s ease;
        }
        
        .card:hover {
            transform: translateY(-2px);
        }
        
        .stat-card {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            border-radius: 12px;
            padding: 20px;
        }
        
        .stat-card .stat-value {
            font-size: 2.5rem;
            font-weight: bold;
        }
        
        .stat-card .stat-label {
            opacity: 0.9;
            font-size: 0.9rem;
        }
        
        .btn-primary {
            background: var(--primary-color);
            border: none;
            padding: 10px 20px;
            border-radius: 8px;
        }
        
        .btn-primary:hover {
            background: var(--secondary-color);
        }
        
        .table-hover tbody tr:hover {
            background-color: rgba(67, 97, 238, 0.05);
        }
        
        .badge-status {
            padding: 6px 12px;
            border-radius: 20px;
            font-weight: 500;
        }
        
        .badge-draft { background-color: #6c757d; color: white; }
        .badge-processing { background-color: #fd7e14; color: white; }
        .badge-active { background-color: #198754; color: white; }
        .badge-error { background-color: #dc3545; color: white; }
        
        .channel-player {
            background: #000;
            border-radius: 8px;
            overflow: hidden;
        }
        
        @media (max-width: 768px) {
            .sidebar {
                min-height: auto;
            }
            
            .main-content {
                padding: 15px;
            }
        }
    </style>
    
    {% block extra_css %}{% endblock %}
</head>
<body>
    <div class="container-fluid">
        <div class="row">
            <!-- Sidebar -->
            <nav class="col-md-3 col-lg-2 d-md-block sidebar collapse">
                <div class="position-sticky pt-3">
                    <div class="text-center mb-4">
                        <h3 class="fw-bold">
                            <i class="bi bi-broadcast"></i> HLS Manager
                        </h3>
                        <small class="text-light opacity-75">Sistema de Gerenciamento de Canais</small>
                    </div>
                    
                    <ul class="nav flex-column">
                        <li class="nav-item">
                            <a class="nav-link {% if request.endpoint == 'main.index' %}active{% endif %}" 
                               href="{{ url_for('main.index') }}">
                                <i class="bi bi-speedometer2"></i> Dashboard
                            </a>
                        </li>
                        
                        <li class="nav-item">
                            <a class="nav-link {% if 'channels' in request.endpoint %}active{% endif %}" 
                               href="{{ url_for('channels.list_channels') }}">
                                <i class="bi bi-collection-play"></i> Canais
                            </a>
                        </li>
                        
                        <li class="nav-item">
                            <a class="nav-link" href="{{ url_for('channels.create_channel') }}">
                                <i class="bi bi-plus-circle"></i> Novo Canal
                            </a>
                        </li>
                        
                        <li class="nav-item mt-4">
                            <div class="nav-link text-light opacity-75">
                                <i class="bi bi-gear"></i> Configurações
                            </div>
                        </li>
                        
                        <li class="nav-item">
                            <a class="nav-link {% if request.endpoint == 'auth.profile' %}active{% endif %}" 
                               href="{{ url_for('auth.profile') }}">
                                <i class="bi bi-person-circle"></i> Perfil
                            </a>
                        </li>
                        
                        <li class="nav-item">
                            <a class="nav-link text-danger" href="{{ url_for('auth.logout') }}">
                                <i class="bi bi-box-arrow-right"></i> Sair
                            </a>
                        </li>
                    </ul>
                    
                    <div class="mt-5 px-3">
                        <div class="card bg-dark text-white">
                            <div class="card-body">
                                <h6 class="card-title">
                                    <i class="bi bi-info-circle"></i> Sistema
                                </h6>
                                <p class="card-text small">
                                    <i class="bi bi-calendar-check"></i> {{ current_year }}
                                    <br>
                                    <i class="bi bi-person-fill"></i> {{ current_user.username }}
                                </p>
                            </div>
                        </div>
                    </div>
                </div>
            </nav>
            
            <!-- Main Content -->
            <main class="col-md-9 ms-sm-auto col-lg-10 px-md-4 main-content">
                <!-- Flash Messages -->
                {% with messages = get_flashed_messages(with_categories=true) %}
                    {% if messages %}
                        {% for category, message in messages %}
                            <div class="alert alert-{{ category }} alert-dismissible fade show mt-3" role="alert">
                                {{ message }}
                                <button type="button" class="btn-close" data-bs-dismiss="alert"></button>
                            </div>
                        {% endfor %}
                    {% endif %}
                {% endwith %}
                
                <!-- Page Header -->
                <div class="d-flex justify-content-between flex-wrap flex-md-nowrap align-items-center pt-3 pb-2 mb-3 border-bottom">
                    <h1 class="h2">{% block page_title %}Dashboard{% endblock %}</h1>
                    <div class="btn-toolbar mb-2 mb-md-0">
                        {% block page_actions %}{% endblock %}
                    </div>
                </div>
                
                <!-- Page Content -->
                {% block content %}{% endblock %}
            </main>
        </div>
    </div>
    
    <!-- Scripts -->
    <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.1.3/dist/js/bootstrap.bundle.min.js"></script>
    <script src="https://code.jquery.com/jquery-3.6.0.min.js"></script>
    <script src="https://cdn.datatables.net/1.11.5/js/jquery.dataTables.min.js"></script>
    <script src="https://cdn.datatables.net/1.11.5/js/dataTables.bootstrap5.min.js"></script>
    
    <script>
        // Inicializar DataTables
        $(document).ready(function() {
            $('.data-table').DataTable({
                language: {
                    url: 'https://cdn.datatables.net/plug-ins/1.11.5/i18n/pt-BR.json'
                },
                pageLength: 25,
                responsive: true
            });
        });
        
        // Auto-hide alerts after 5 seconds
        setTimeout(function() {
            $('.alert').alert('close');
        }, 5000);
        
        // Confirmar ações destrutivas
        function confirmAction(message) {
            return confirm(message || 'Tem certeza que deseja continuar?');
        }
    </script>
    
    {% block extra_js %}{% endblock %}
</body>
</html>
EOF

# Template de login
sudo tee /opt/hls-manager/app/templates/auth/login.html > /dev/null << 'EOF'
{% extends "layout/base.html" %}

{% block title %}Login - HLS Manager{% endblock %}

{% block content %}
<div class="container mt-5">
    <div class="row justify-content-center">
        <div class="col-md-6 col-lg-4">
            <div class="card shadow">
                <div class="card-body p-4">
                    <div class="text-center mb-4">
                        <h2 class="fw-bold text-primary">
                            <i class="bi bi-broadcast"></i> HLS Manager
                        </h2>
                        <p class="text-muted">Faça login para acessar o sistema</p>
                    </div>
                    
                    <form method="POST" action="{{ url_for('auth.login') }}">
                        {{ form.hidden_tag() }}
                        
                        <div class="mb-3">
                            <label for="username" class="form-label">
                                <i class="bi bi-person"></i> Usuário
                            </label>
                            {{ form.username(class="form-control", placeholder="Digite seu usuário") }}
                            {% for error in form.username.errors %}
                                <div class="text-danger small">{{ error }}</div>
                            {% endfor %}
                        </div>
                        
                        <div class="mb-3">
                            <label for="password" class="form-label">
                                <i class="bi bi-lock"></i> Senha
                            </label>
                            {{ form.password(class="form-control", placeholder="Digite sua senha") }}
                            {% for error in form.password.errors %}
                                <div class="text-danger small">{{ error }}</div>
                            {% endfor %}
                        </div>
                        
                        <div class="mb-3 form-check">
                            {{ form.remember(class="form-check-input") }}
                            <label class="form-check-label" for="remember">
                                Lembrar-me
                            </label>
                        </div>
                        
                        <div class="d-grid gap-2">
                            <button type="submit" class="btn btn-primary btn-lg">
                                <i class="bi bi-box-arrow-in-right"></i> Entrar
                            </button>
                        </div>
                    </form>
                    
                    <div class="mt-4 text-center">
                        <p class="text-muted">
                            Sistema de Gerenciamento de Canais HLS
                            <br>
                            <small>v2.0.0</small>
                        </p>
                    </div>
                </div>
            </div>
        </div>
    </div>
</div>
{% endblock %}
EOF

# 22. Criar serviço systemd
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
RestrictSUIDSGID=true
MemoryDenyWriteExecute=true

# Limites de recursos
LimitNOFILE=65536
LimitNPROC=512

# Execução
ExecStart=/opt/hls-manager/venv/bin/gunicorn \
  --bind 127.0.0.1:5000 \
  --workers 4 \
  --threads 2 \
  --timeout 120 \
  --access-logfile /opt/hls-manager/logs/gunicorn-access.log \
  --error-logfile /opt/hls-manager/logs/gunicorn-error.log \
  --capture-output \
  --log-level info \
  run:app

# Reinício automático
Restart=always
RestartSec=10
StartLimitInterval=60
StartLimitBurst=5

# Logs
StandardOutput=journal
StandardError=journal
SyslogIdentifier=hls-manager

[Install]
WantedBy=multi-user.target
EOF

# 23. Configurar Nginx
echo "🌐 Configurando Nginx..."
sudo tee /etc/nginx/sites-available/hls-manager > /dev/null << 'EOF'
server {
    listen 80;
    server_name _;
    
    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net; style-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net; font-src 'self' https://cdn.jsdelivr.net; img-src 'self' data:;" always;
    
    # Upload size limit
    client_max_body_size 2G;
    
    # Proxy para aplicação Flask
    location / {
        proxy_pass http://127.0.0.1:5000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        
        # WebSocket support
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        
        # Timeouts
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
            add_header Cache-Control "no-cache, no-store, must-revalidate";
        }
        
        # Prevenir listagem de diretórios
        autoindex off;
    }
    
    # Bloquear acesso a diretórios sensíveis
    location ~ ^/(uploads|temp|config|logs|backups|\.env)/ {
        deny all;
        return 403;
    }
    
    # Health check
    location /api/health {
        proxy_pass http://127.0.0.1:5000/api/health;
        access_log off;
    }
}
EOF

sudo ln -sf /etc/nginx/sites-available/hls-manager /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default

# 24. Configurar firewall
echo "🔥 Configurando firewall..."
sudo ufw --force enable
sudo ufw allow 22/tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw --force reload

# 25. Inicializar banco de dados
echo "🗃️ Inicializando banco de dados..."
cd /opt/hls-manager
sudo -u hlsmanager ./venv/bin/python run.py initdb

# 26. Configurar migrações do banco
echo "🔄 Configurando migrações do banco..."
cd /opt/hls-manager
sudo -u hlsmanager ./venv/bin/flask db init 2>/dev/null || true
sudo -u hlsmanager ./venv/bin/flask db migrate -m "Initial migration"
sudo -u hlsmanager ./venv/bin/flask db upgrade

# 27. Iniciar serviços
echo "🚀 Iniciando serviços..."
sudo systemctl daemon-reload
sudo systemctl enable hls-manager
sudo systemctl start hls-manager
sudo systemctl enable mariadb
sudo systemctl restart mariadb
sudo systemctl enable nginx
sudo nginx -t && sudo systemctl restart nginx

# 28. Criar script de backup
echo "💾 Criando script de backup..."
sudo tee /opt/hls-manager/scripts/backup.sh > /dev/null << 'EOF'
#!/bin/bash
# Script de backup do HLS Manager

BACKUP_DIR="/opt/hls-manager/backups"
DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="$BACKUP_DIR/backup_$DATE.tar.gz"

# Criar backup
echo "Criando backup em: $BACKUP_FILE"

# Backup do banco de dados
MYSQL_USER="hls_manager"
MYSQL_PASS="HlsAppSecure@2024"
MYSQL_DB="hls_manager"

mysqldump -u$MYSQL_USER -p$MYSQL_PASS $MYSQL_DB > /tmp/hls_manager_db.sql

# Compactar tudo
tar -czf $BACKUP_FILE \
    -C /opt/hls-manager \
    config/.env \
    --transform="s|/tmp/||" \
    /tmp/hls_manager_db.sql

# Limpar
rm -f /tmp/hls_manager_db.sql

# Manter apenas últimos 7 backups
find $BACKUP_DIR -name "backup_*.tar.gz" -mtime +7 -delete

echo "Backup concluído: $BACKUP_FILE"
EOF

sudo chmod +x /opt/hls-manager/scripts/backup.sh
sudo chown hlsmanager:hlsmanager /opt/hls-manager/scripts/backup.sh

# Adicionar ao cron para backup diário
echo "0 2 * * * hlsmanager /opt/hls-manager/scripts/backup.sh >/dev/null 2>&1" | sudo tee -a /etc/cron.d/hls-backup

# 29. Criar script de monitoramento
echo "👁️ Criando script de monitoramento..."
sudo tee /opt/hls-manager/scripts/monitor.sh > /dev/null << 'EOF'
#!/bin/bash
# Monitoramento do HLS Manager

LOG_FILE="/opt/hls-manager/logs/monitor.log"
SERVICE_NAME="hls-manager"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

check_service() {
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        log "✅ Serviço $SERVICE_NAME está rodando"
        return 0
    else
        log "❌ Serviço $SERVICE_NAME parado. Tentando reiniciar..."
        systemctl restart "$SERVICE_NAME"
        sleep 5
        if systemctl is-active --quiet "$SERVICE_NAME"; then
            log "✅ Serviço $SERVICE_NAME reiniciado com sucesso"
            return 0
        else
            log "❌ Falha ao reiniciar $SERVICE_NAME"
            return 1
        fi
    fi
}

check_database() {
    if mysql -u hls_manager -pHlsAppSecure@2024 -e "SELECT 1" hls_manager >/dev/null 2>&1; then
        log "✅ Banco de dados está acessível"
        return 0
    else
        log "❌ Erro ao acessar banco de dados"
        return 1
    fi
}

check_disk_space() {
    USAGE=$(df /opt/hls-manager | tail -1 | awk '{print $5}' | sed 's/%//')
    if [ "$USAGE" -gt 90 ]; then
        log "⚠️ Espaço em disco crítico: ${USAGE}%"
        return 1
    elif [ "$USAGE" -gt 80 ]; then
        log "⚠️ Espaço em disco alto: ${USAGE}%"
        return 0
    else
        return 0
    fi
}

# Executar verificações
check_service
check_database
check_disk_space
EOF

sudo chmod +x /opt/hls-manager/scripts/monitor.sh
sudo chown hlsmanager:hlsmanager /opt/hls-manager/scripts/monitor.sh

# Adicionar ao cron para monitoramento a cada 5 minutos
echo "*/5 * * * * hlsmanager /opt/hls-manager/scripts/monitor.sh >/dev/null 2>&1" | sudo tee -a /etc/cron.d/hls-monitor

# 30. Testar instalação
echo "🧪 Testando instalação..."
sleep 10

# Verificar serviços
services=("hls-manager" "mariadb" "nginx")
for service in "${services[@]}"; do
    if systemctl is-active --quiet "$service"; then
        echo "✅ Serviço $service está rodando"
    else
        echo "❌ Erro: Serviço $service não iniciou"
        sudo systemctl status "$service" --no-pager
        exit 1
    fi
done

# 31. Mostrar informações finais
IP=$(curl -s ifconfig.me || hostname -I | awk '{print $1}')
echo ""
echo "🎉 HLS MANAGER INSTALADO COM SUCESSO!"
echo ""
echo "🔐 INFORMAÇÕES DE ACESSO:"
echo "• URL: http://$IP"
echo "• Usuário: admin"
echo "• Senha: $ADMIN_PASSWORD"
echo ""
echo "📊 BANCO DE DADOS:"
echo "• Host: localhost"
echo "• Banco: hls_manager"
echo "• Usuário: hls_manager"
echo "• Senha: $MYSQL_APP_PASS"
echo ""
echo "📁 ESTRUTURA DE DIRETÓRIOS:"
echo "/opt/hls-manager/"
echo "├── app/              # Aplicação Flask"
echo "├── uploads/          # Uploads temporários"
echo "├── hls/              # Arquivos HLS gerados"
echo "├── logs/             # Logs da aplicação"
echo "├── config/           # Configurações"
echo "├── backups/          # Backups automáticos"
echo "└── scripts/          # Scripts de manutenção"
echo ""
echo "⚙️ COMANDOS ÚTEIS:"
echo "• Dashboard: http://$IP"
echo "• Status serviços: sudo systemctl status hls-manager"
echo "• Ver logs: sudo journalctl -u hls-manager -f"
echo "• Backup manual: sudo -u hlsmanager /opt/hls-manager/scripts/backup.sh"
echo ""
echo "🎬 FUNCIONALIDADES:"
echo "✓ Painel de gerenciamento completo"
echo "✓ Criação de canais com upload de vídeos"
echo "✓ Conversão automática para HLS"
echo "✓ Player integrado"
echo "✓ Edição e exclusão de canais"
echo "✓ Banco de dados MariaDB"
echo "✓ Backup automático"
echo "✓ Monitoramento"
echo ""
echo "🚀 Sistema pronto para uso em produção!"
echo "⚠️ Importante: Altere a senha do administrador após o primeiro login!"
echo ""
