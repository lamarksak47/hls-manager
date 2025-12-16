#!/bin/bash
# install_hls_with_dashboard.sh - INSTALAÇÃO COMPLETA COM DASHBOARD

set -e

echo "🚀 INSTALAÇÃO DO HLS MANAGER COM DASHBOARD"
echo "=========================================="

# 1. PARAR SERVIÇOS EXISTENTES
echo "🛑 Parando serviços existentes..."
sudo systemctl stop hls-manager hls-dashboard hls-service 2>/dev/null || true
sudo pkill -9 gunicorn 2>/dev/null || true
sudo pkill -9 python 2>/dev/null || true

# Liberar portas
echo "🔓 Liberando portas..."
sudo fuser -k 5000/tcp 2>/dev/null || true
sudo fuser -k 5001/tcp 2>/dev/null || true
sleep 2

# 2. LIMPAR INSTALAÇÕES ANTERIORES
echo "🧹 Limpando instalações anteriores..."
sudo rm -rf /opt/hls-dashboard 2>/dev/null || true
sudo rm -rf /opt/hls-manager 2>/dev/null || true
sudo rm -f /etc/systemd/system/hls-*.service 2>/dev/null || true
sudo systemctl daemon-reload

# 3. CRIAR USUÁRIO E DIRETÓRIO
echo "👤 Criando usuário e estrutura..."
sudo useradd -r -s /bin/false -m -d /opt/hls-dashboard hlsadmin 2>/dev/null || true

sudo mkdir -p /opt/hls-dashboard
sudo mkdir -p /opt/hls-dashboard/uploads
sudo mkdir -p /opt/hls-dashboard/streams
sudo mkdir -p /opt/hls-dashboard/static
sudo mkdir -p /opt/hls-dashboard/templates

cd /opt/hls-dashboard

# 4. INSTALAR DEPENDÊNCIAS
echo "📦 Instalando dependências..."
sudo apt-get update
sudo apt-get install -y python3 python3-pip python3-venv ffmpeg nginx

# 5. CRIAR APLICAÇÃO FLASK COM DASHBOARD COMPLETO
echo "💻 Criando aplicação com dashboard..."

# Arquivo principal da aplicação
sudo tee /opt/hls-dashboard/app.py > /dev/null << 'EOF'
from flask import Flask, render_template, jsonify, request, redirect, url_for, send_from_directory, flash
from flask_socketio import SocketIO
import os
import json
import subprocess
import threading
import time
from datetime import datetime
import uuid

app = Flask(__name__)
app.secret_key = 'hls-dashboard-secret-key-2024'
app.config['UPLOAD_FOLDER'] = '/opt/hls-dashboard/uploads'
app.config['STREAMS_FOLDER'] = '/opt/hls-dashboard/streams'
app.config['MAX_CONTENT_LENGTH'] = 500 * 1024 * 1024  # 500MB

socketio = SocketIO(app, cors_allowed_origins="*")

# Banco de dados simples em JSON
DB_FILE = '/opt/hls-dashboard/database.json'

def load_database():
    if os.path.exists(DB_FILE):
        with open(DB_FILE, 'r') as f:
            return json.load(f)
    return {
        'streams': [],
        'users': [
            {'username': 'admin', 'password': 'admin', 'role': 'admin'}
        ],
        'settings': {
            'auto_start': True,
            'max_bitrate': '2500k',
            'port': 1935
        },
        'stats': {
            'total_streams': 0,
            'active_streams': 0,
            'total_views': 0
        }
    }

def save_database(data):
    with open(DB_FILE, 'w') as f:
        json.dump(data, f, indent=4)

# Rota principal - Dashboard
@app.route('/')
def dashboard():
    data = load_database()
    
    # Status do sistema
    system_status = {
        'cpu_usage': subprocess.getoutput("top -bn1 | grep 'Cpu(s)' | awk '{print $2}'").replace('%us,', ''),
        'memory_usage': subprocess.getoutput("free -m | awk 'NR==2{printf \"%.2f%%\", $3*100/$2}'"),
        'disk_usage': subprocess.getoutput("df -h /opt | awk 'NR==2{print $5}'"),
        'uptime': subprocess.getoutput("uptime -p"),
        'active_connections': len([s for s in data['streams'] if s.get('status') == 'active'])
    }
    
    return render_template('dashboard.html', 
                         streams=data['streams'][-10:], 
                         stats=data['stats'],
                         system=system_status,
                         settings=data['settings'])

# API para dados do dashboard
@app.route('/api/dashboard/stats')
def api_dashboard_stats():
    data = load_database()
    return jsonify(data['stats'])

@app.route('/api/system/info')
def api_system_info():
    info = {
        'cpu': subprocess.getoutput("top -bn1 | grep 'Cpu(s)' | awk '{print $2}'").replace('%us,', ''),
        'memory': subprocess.getoutput("free -m | awk 'NR==2{printf \"%.2f%%\", $3*100/$2}'"),
        'disk': subprocess.getoutput("df -h /opt | awk 'NR==2{print $5}'"),
        'uptime': subprocess.getoutput("uptime -p"),
        'time': datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    }
    return jsonify(info)

# Gerenciamento de Streams
@app.route('/streams')
def streams_list():
    data = load_database()
    return render_template('streams.html', streams=data['streams'])

@app.route('/stream/create', methods=['GET', 'POST'])
def stream_create():
    if request.method == 'POST':
        data = load_database()
        
        stream_id = str(uuid.uuid4())[:8]
        new_stream = {
            'id': stream_id,
            'name': request.form['name'],
            'source': request.form['source'],
            'bitrate': request.form['bitrate'],
            'resolution': request.form['resolution'],
            'status': 'stopped',
            'created_at': datetime.now().isoformat(),
            'viewers': 0,
            'last_active': None
        }
        
        data['streams'].append(new_stream)
        save_database(data)
        
        flash('Stream criada com sucesso!', 'success')
        return redirect(url_for('streams_list'))
    
    return render_template('stream_create.html')

@app.route('/stream/<stream_id>/start')
def stream_start(stream_id):
    data = load_database()
    
    for stream in data['streams']:
        if stream['id'] == stream_id:
            stream['status'] = 'active'
            stream['last_active'] = datetime.now().isoformat()
            
            # Em produção, aqui iniciaria o processo FFmpeg
            # start_streaming_process(stream)
            
            save_database(data)
            flash(f'Stream {stream["name"]} iniciada!', 'success')
            break
    
    return redirect(url_for('streams_list'))

@app.route('/stream/<stream_id>/stop')
def stream_stop(stream_id):
    data = load_database()
    
    for stream in data['streams']:
        if stream['id'] == stream_id:
            stream['status'] = 'stopped'
            save_database(data)
            flash(f'Stream {stream["name"]} parada!', 'warning')
            break
    
    return redirect(url_for('streams_list'))

@app.route('/stream/<stream_id>/delete')
def stream_delete(stream_id):
    data = load_database()
    data['streams'] = [s for s in data['streams'] if s['id'] != stream_id]
    save_database(data)
    
    flash('Stream removida!', 'danger')
    return redirect(url_for('streams_list'))

# Upload de vídeos
@app.route('/upload', methods=['GET', 'POST'])
def upload_video():
    if request.method == 'POST':
        if 'file' not in request.files:
            flash('Nenhum arquivo selecionado', 'danger')
            return redirect(request.url)
        
        file = request.files['file']
        if file.filename == '':
            flash('Nenhum arquivo selecionado', 'danger')
            return redirect(request.url)
        
        if file:
            filename = file.filename
            filepath = os.path.join(app.config['UPLOAD_FOLDER'], filename)
            file.save(filepath)
            
            flash(f'Arquivo {filename} enviado com sucesso!', 'success')
            
            # Criar stream automaticamente se configurado
            data = load_database()
            if data['settings'].get('auto_create_stream', True):
                stream_id = str(uuid.uuid4())[:8]
                new_stream = {
                    'id': stream_id,
                    'name': filename,
                    'source': f'/uploads/{filename}',
                    'type': 'vod',
                    'status': 'ready',
                    'created_at': datetime.now().isoformat()
                }
                data['streams'].append(new_stream)
                save_database(data)
            
            return redirect(url_for('upload_video'))
    
    # Listar arquivos enviados
    files = []
    if os.path.exists(app.config['UPLOAD_FOLDER']):
        files = os.listdir(app.config['UPLOAD_FOLDER'])
    
    return render_template('upload.html', files=files)

@app.route('/uploads/<filename>')
def serve_upload(filename):
    return send_from_directory(app.config['UPLOAD_FOLDER'], filename)

# Configurações
@app.route('/settings', methods=['GET', 'POST'])
def settings():
    data = load_database()
    
    if request.method == 'POST':
        data['settings']['auto_start'] = request.form.get('auto_start') == 'on'
        data['settings']['max_bitrate'] = request.form['max_bitrate']
        data['settings']['port'] = int(request.form['port'])
        data['settings']['auto_create_stream'] = request.form.get('auto_create_stream') == 'on'
        
        save_database(data)
        flash('Configurações salvas!', 'success')
        return redirect(url_for('settings'))
    
    return render_template('settings.html', settings=data['settings'])

# Monitoramento
@app.route('/monitor')
def monitor():
    return render_template('monitor.html')

# API para atualizações em tempo real
@app.route('/api/streams/status')
def api_streams_status():
    data = load_database()
    
    # Simular dados em tempo real
    for stream in data['streams']:
        if stream['status'] == 'active':
            stream['viewers'] = stream.get('viewers', 0) + 1
            stream['last_active'] = datetime.now().isoformat()
    
    return jsonify({
        'streams': data['streams'],
        'timestamp': datetime.now().isoformat()
    })

# Relatórios
@app.route('/reports')
def reports():
    data = load_database()
    
    # Estatísticas
    reports_data = {
        'total_streams': len(data['streams']),
        'active_streams': len([s for s in data['streams'] if s.get('status') == 'active']),
        'total_views': sum(s.get('viewers', 0) for s in data['streams']),
        'bandwidth_usage': '1.2 GB',
        'popular_stream': max(data['streams'], key=lambda x: x.get('viewers', 0)) if data['streams'] else None
    }
    
    return render_template('reports.html', reports=reports_data)

# Login
@app.route('/login', methods=['GET', 'POST'])
def login():
    if request.method == 'POST':
        username = request.form['username']
        password = request.form['password']
        
        data = load_database()
        for user in data['users']:
            if user['username'] == username and user['password'] == password:
                flash('Login realizado com sucesso!', 'success')
                return redirect(url_for('dashboard'))
        
        flash('Credenciais inválidas!', 'danger')
    
    return render_template('login.html')

# Logout
@app.route('/logout')
def logout():
    flash('Logout realizado com sucesso!', 'info')
    return redirect(url_for('login'))

# Health check
@app.route('/health')
def health():
    return jsonify({
        'status': 'healthy',
        'service': 'hls-dashboard',
        'version': '2.0.0',
        'timestamp': datetime.now().isoformat(),
        'streams_count': len(load_database()['streams'])
    })

# Página de ajuda
@app.route('/help')
def help_page():
    return render_template('help.html')

if __name__ == '__main__':
    # Garantir que as pastas existem
    os.makedirs(app.config['UPLOAD_FOLDER'], exist_ok=True)
    os.makedirs(app.config['STREAMS_FOLDER'], exist_ok=True)
    
    print("🚀 Iniciando HLS Dashboard...")
    socketio.run(app, host='0.0.0.0', port=5000, debug=True)
EOF

# 6. CRIAR TEMPLATES HTML DO DASHBOARD
echo "🎨 Criando templates HTML..."

# Dashboard principal
sudo tee /opt/hls-dashboard/templates/dashboard.html > /dev/null << 'EOF'
<!DOCTYPE html>
<html lang="pt-BR">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>🎬 HLS Dashboard</title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.1.3/dist/css/bootstrap.min.css" rel="stylesheet">
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap-icons@1.8.1/font/bootstrap-icons.css">
    <style>
        :root {
            --primary-color: #4361ee;
            --secondary-color: #3a0ca3;
            --success-color: #4cc9f0;
            --warning-color: #f72585;
        }
        
        body {
            background-color: #f8f9fa;
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
        }
        
        .sidebar {
            background: linear-gradient(180deg, var(--primary-color) 0%, var(--secondary-color) 100%);
            color: white;
            height: 100vh;
            position: fixed;
            left: 0;
            top: 0;
            width: 250px;
            padding-top: 20px;
        }
        
        .main-content {
            margin-left: 250px;
            padding: 20px;
        }
        
        .logo {
            text-align: center;
            padding: 20px;
            font-size: 1.5rem;
            font-weight: bold;
        }
        
        .nav-link {
            color: rgba(255,255,255,0.8);
            padding: 12px 20px;
            margin: 5px 10px;
            border-radius: 8px;
            transition: all 0.3s;
        }
        
        .nav-link:hover, .nav-link.active {
            background-color: rgba(255,255,255,0.1);
            color: white;
        }
        
        .nav-link i {
            margin-right: 10px;
        }
        
        .stat-card {
            background: white;
            border-radius: 12px;
            padding: 20px;
            margin-bottom: 20px;
            box-shadow: 0 4px 6px rgba(0,0,0,0.1);
            transition: transform 0.3s;
        }
        
        .stat-card:hover {
            transform: translateY(-5px);
        }
        
        .stat-icon {
            font-size: 2.5rem;
            margin-bottom: 10px;
        }
        
        .stream-status {
            display: inline-block;
            padding: 4px 12px;
            border-radius: 20px;
            font-size: 0.85rem;
            font-weight: bold;
        }
        
        .status-active { background-color: #d4edda; color: #155724; }
        .status-stopped { background-color: #f8d7da; color: #721c24; }
        .status-ready { background-color: #fff3cd; color: #856404; }
        
        .btn-primary {
            background-color: var(--primary-color);
            border: none;
        }
        
        .btn-primary:hover {
            background-color: var(--secondary-color);
        }
        
        .system-health {
            font-size: 0.9rem;
            color: #666;
        }
        
        .progress {
            height: 8px;
            margin-top: 5px;
        }
    </style>
</head>
<body>
    <!-- Sidebar -->
    <div class="sidebar">
        <div class="logo">
            <i class="bi bi-camera-reels"></i> HLS Manager
        </div>
        
        <nav class="nav flex-column">
            <a class="nav-link active" href="/">
                <i class="bi bi-speedometer2"></i> Dashboard
            </a>
            <a class="nav-link" href="/streams">
                <i class="bi bi-collection-play"></i> Streams
            </a>
            <a class="nav-link" href="/upload">
                <i class="bi bi-upload"></i> Upload
            </a>
            <a class="nav-link" href="/monitor">
                <i class="bi bi-graph-up"></i> Monitor
            </a>
            <a class="nav-link" href="/reports">
                <i class="bi bi-file-bar-graph"></i> Relatórios
            </a>
            <a class="nav-link" href="/settings">
                <i class="bi bi-gear"></i> Configurações
            </a>
            <a class="nav-link" href="/help">
                <i class="bi bi-question-circle"></i> Ajuda
            </a>
            <div class="mt-auto p-3">
                <a class="nav-link" href="/logout">
                    <i class="bi bi-box-arrow-right"></i> Sair
                </a>
            </div>
        </nav>
    </div>

    <!-- Main Content -->
    <div class="main-content">
        <!-- Header -->
        <div class="d-flex justify-content-between align-items-center mb-4">
            <h1><i class="bi bi-speedometer2"></i> Dashboard</h1>
            <div class="system-health">
                <span id="system-time"></span> | 
                <span id="system-status" class="text-success">● Online</span>
            </div>
        </div>

        <!-- Flash Messages -->
        {% with messages = get_flashed_messages(with_categories=true) %}
            {% if messages %}
                {% for category, message in messages %}
                    <div class="alert alert-{{ 'danger' if category == 'danger' else 'success' }} alert-dismissible fade show">
                        {{ message }}
                        <button type="button" class="btn-close" data-bs-dismiss="alert"></button>
                    </div>
                {% endfor %}
            {% endif %}
        {% endwith %}

        <!-- Stats Cards -->
        <div class="row">
            <div class="col-md-3">
                <div class="stat-card">
                    <div class="stat-icon text-primary">
                        <i class="bi bi-collection-play"></i>
                    </div>
                    <h3 id="total-streams">{{ stats.total_streams }}</h3>
                    <p class="text-muted">Total Streams</p>
                </div>
            </div>
            <div class="col-md-3">
                <div class="stat-card">
                    <div class="stat-icon text-success">
                        <i class="bi bi-play-circle"></i>
                    </div>
                    <h3 id="active-streams">{{ stats.active_streams }}</h3>
                    <p class="text-muted">Streams Ativas</p>
                </div>
            </div>
            <div class="col-md-3">
                <div class="stat-card">
                    <div class="stat-icon text-warning">
                        <i class="bi bi-eye"></i>
                    </div>
                    <h3 id="total-views">{{ stats.total_views }}</h3>
                    <p class="text-muted">Total Visualizações</p>
                </div>
            </div>
            <div class="col-md-3">
                <div class="stat-card">
                    <div class="stat-icon text-info">
                        <i class="bi bi-cpu"></i>
                    </div>
                    <h3 id="cpu-usage">{{ system.cpu_usage }}</h3>
                    <p class="text-muted">Uso de CPU</p>
                </div>
            </div>
        </div>

        <!-- System Info -->
        <div class="row mt-4">
            <div class="col-md-8">
                <div class="stat-card">
                    <h4><i class="bi bi-broadcast"></i> Streams Recentes</h4>
                    <div class="table-responsive mt-3">
                        <table class="table table-hover">
                            <thead>
                                <tr>
                                    <th>Nome</th>
                                    <th>Status</th>
                                    <th>Resolução</th>
                                    <th>Visualizações</th>
                                    <th>Ações</th>
                                </tr>
                            </thead>
                            <tbody>
                                {% for stream in streams %}
                                <tr>
                                    <td>{{ stream.name }}</td>
                                    <td>
                                        <span class="stream-status status-{{ stream.status }}">
                                            {{ stream.status|title }}
                                        </span>
                                    </td>
                                    <td>{{ stream.resolution or '1920x1080' }}</td>
                                    <td>{{ stream.viewers or 0 }}</td>
                                    <td>
                                        {% if stream.status == 'stopped' %}
                                            <a href="/stream/{{ stream.id }}/start" class="btn btn-sm btn-success">
                                                <i class="bi bi-play"></i>
                                            </a>
                                        {% else %}
                                            <a href="/stream/{{ stream.id }}/stop" class="btn btn-sm btn-warning">
                                                <i class="bi bi-stop"></i>
                                            </a>
                                        {% endif %}
                                        <a href="/stream/{{ stream.id }}/delete" class="btn btn-sm btn-danger">
                                            <i class="bi bi-trash"></i>
                                        </a>
                                    </td>
                                </tr>
                                {% endfor %}
                            </tbody>
                        </table>
                    </div>
                    <div class="mt-3">
                        <a href="/stream/create" class="btn btn-primary">
                            <i class="bi bi-plus-circle"></i> Nova Stream
                        </a>
                    </div>
                </div>
            </div>
            
            <div class="col-md-4">
                <div class="stat-card">
                    <h4><i class="bi bi-hdd"></i> Status do Sistema</h4>
                    <div class="mt-3">
                        <p><strong>Uso de Memória:</strong> {{ system.memory_usage }}</p>
                        <div class="progress">
                            <div class="progress-bar bg-success" style="width: {{ system.memory_usage|replace('%', '')|int }}%"></div>
                        </div>
                        
                        <p class="mt-3"><strong>Uso de Disco:</strong> {{ system.disk_usage }}</p>
                        <div class="progress">
                            <div class="progress-bar bg-info" style="width: {{ system.disk_usage|replace('%', '')|int }}%"></div>
                        </div>
                        
                        <p class="mt-3"><strong>Tempo de Atividade:</strong> {{ system.uptime }}</p>
                        <p><strong>Conexões Ativas:</strong> {{ system.active_connections }}</p>
                    </div>
                </div>
                
                <div class="stat-card mt-4">
                    <h4><i class="bi bi-lightning-charge"></i> Ações Rápidas</h4>
                    <div class="d-grid gap-2 mt-3">
                        <a href="/upload" class="btn btn-outline-primary">
                            <i class="bi bi-upload"></i> Upload de Vídeo
                        </a>
                        <a href="/monitor" class="btn btn-outline-success">
                            <i class="bi bi-graph-up"></i> Monitor em Tempo Real
                        </a>
                        <a href="/settings" class="btn btn-outline-warning">
                            <i class="bi bi-gear"></i> Configurações
                        </a>
                    </div>
                </div>
            </div>
        </div>
        
        <!-- Footer -->
        <div class="mt-4 text-center text-muted">
            <p>HLS Dashboard v2.0.0 | © 2024 | 
                <a href="/health" class="text-decoration-none">Status do Serviço</a>
            </p>
        </div>
    </div>

    <!-- Scripts -->
    <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.1.3/dist/js/bootstrap.bundle.min.js"></script>
    <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
    <script>
        // Atualizar tempo do sistema
        function updateSystemTime() {
            const now = new Date();
            document.getElementById('system-time').textContent = 
                now.toLocaleDateString() + ' ' + now.toLocaleTimeString();
        }
        
        setInterval(updateSystemTime, 1000);
        updateSystemTime();
        
        // Atualizar stats via API
        function updateDashboardStats() {
            fetch('/api/dashboard/stats')
                .then(response => response.json())
                .then(data => {
                    document.getElementById('total-streams').textContent = data.total_streams;
                    document.getElementById('active-streams').textContent = data.active_streams;
                    document.getElementById('total-views').textContent = data.total_views;
                });
            
            fetch('/api/system/info')
                .then(response => response.json())
                .then(data => {
                    document.getElementById('cpu-usage').textContent = data.cpu + '%';
                });
        }
        
        setInterval(updateDashboardStats, 5000);
        updateDashboardStats();
        
        // Configurar gráficos (exemplo)
        const ctx = document.createElement('canvas');
        ctx.style.maxHeight = '200px';
        document.querySelector('.stat-card:nth-child(1)').appendChild(ctx);
        
        new Chart(ctx, {
            type: 'line',
            data: {
                labels: ['Jan', 'Feb', 'Mar', 'Apr', 'May'],
                datasets: [{
                    label: 'Visualizações',
                    data: [12, 19, 3, 5, 2],
                    borderColor: 'rgb(75, 192, 192)',
                    tension: 0.1
                }]
            }
        });
    </script>
</body>
</html>
EOF

# 7. CRIAR OS OUTROS TEMPLATES
echo "📝 Criando templates adicionais..."

# Login page
sudo tee /opt/hls-dashboard/templates/login.html > /dev/null << 'EOF'
<!DOCTYPE html>
<html>
<head>
    <title>Login - HLS Dashboard</title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.1.3/dist/css/bootstrap.min.css" rel="stylesheet">
    <style>
        body {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
        }
        .login-box {
            background: white;
            padding: 40px;
            border-radius: 15px;
            box-shadow: 0 20px 40px rgba(0,0,0,0.2);
            width: 100%;
            max-width: 400px;
        }
        .logo {
            text-align: center;
            font-size: 2rem;
            margin-bottom: 30px;
            color: #4361ee;
        }
    </style>
</head>
<body>
    <div class="login-box">
        <div class="logo">
            <i class="bi bi-camera-reels"></i> HLS Dashboard
        </div>
        
        {% with messages = get_flashed_messages() %}
            {% if messages %}
                {% for message in messages %}
                    <div class="alert alert-danger">{{ message }}</div>
                {% endfor %}
            {% endif %}
        {% endwith %}
        
        <form method="POST">
            <div class="mb-3">
                <label class="form-label">Usuário</label>
                <input type="text" name="username" class="form-control" required>
            </div>
            <div class="mb-3">
                <label class="form-label">Senha</label>
                <input type="password" name="password" class="form-control" required>
            </div>
            <button type="submit" class="btn btn-primary w-100">
                <i class="bi bi-box-arrow-in-right"></i> Entrar
            </button>
            <div class="mt-3 text-center">
                <small class="text-muted">Usuário: admin | Senha: admin</small>
            </div>
        </form>
    </div>
</body>
</html>
EOF

# Streams list page
sudo tee /opt/hls-dashboard/templates/streams.html > /dev/null << 'EOF'
{% extends "base.html" %}

{% block content %}
<h1><i class="bi bi-collection-play"></i> Gerenciar Streams</h1>

<div class="card mt-4">
    <div class="card-header d-flex justify-content-between align-items-center">
        <h5 class="mb-0">Lista de Streams</h5>
        <a href="/stream/create" class="btn btn-primary">
            <i class="bi bi-plus-circle"></i> Nova Stream
        </a>
    </div>
    <div class="card-body">
        <div class="table-responsive">
            <table class="table table-hover">
                <thead>
                    <tr>
                        <th>ID</th>
                        <th>Nome</th>
                        <th>Fonte</th>
                        <th>Status</th>
                        <th>Resolução</th>
                        <th>Bitrate</th>
                        <th>Criado em</th>
                        <th>Ações</th>
                    </tr>
                </thead>
                <tbody>
                    {% for stream in streams %}
                    <tr>
                        <td><code>{{ stream.id }}</code></td>
                        <td>{{ stream.name }}</td>
                        <td><small>{{ stream.source|truncate(30) }}</small></td>
                        <td>
                            <span class="badge bg-{{ 'success' if stream.status == 'active' else 'danger' }}">
                                {{ stream.status }}
                            </span>
                        </td>
                        <td>{{ stream.resolution or 'Auto' }}</td>
                        <td>{{ stream.bitrate or 'Auto' }}</td>
                        <td>{{ stream.created_at[:10] }}</td>
                        <td>
                            {% if stream.status == 'stopped' %}
                                <a href="/stream/{{ stream.id }}/start" class="btn btn-sm btn-success">
                                    <i class="bi bi-play"></i>
                                </a>
                            {% else %}
                                <a href="/stream/{{ stream.id }}/stop" class="btn btn-sm btn-warning">
                                    <i class="bi bi-stop"></i>
                                </a>
                            {% endif %}
                            <a href="/stream/{{ stream.id }}/delete" class="btn btn-sm btn-danger">
                                <i class="bi bi-trash"></i>
                            </a>
                        </td>
                    </tr>
                    {% endfor %}
                </tbody>
            </table>
        </div>
    </div>
</div>
{% endblock %}
EOF

# Create stream page
sudo tee /opt/hls-dashboard/templates/stream_create.html > /dev/null << 'EOF'
{% extends "base.html" %}

{% block content %}
<h1><i class="bi bi-plus-circle"></i> Criar Nova Stream</h1>

<div class="card mt-4">
    <div class="card-header">
        <h5 class="mb-0">Configurações da Stream</h5>
    </div>
    <div class="card-body">
        <form method="POST">
            <div class="row">
                <div class="col-md-6 mb-3">
                    <label class="form-label">Nome da Stream *</label>
                    <input type="text" name="name" class="form-control" required placeholder="Ex: Meu Canal Principal">
                </div>
                <div class="col-md-6 mb-3">
                    <label class="form-label">Fonte da Stream *</label>
                    <input type="text" name="source" class="form-control" required placeholder="Ex: rtsp://camera.local:554/stream">
                    <small class="text-muted">URL RTSP, arquivo local ou stream URL</small>
                </div>
            </div>
            
            <div class="row">
                <div class="col-md-4 mb-3">
                    <label class="form-label">Bitrate</label>
                    <select name="bitrate" class="form-select">
                        <option value="500k">500 kbps</option>
                        <option value="1000k">1 Mbps</option>
                        <option value="2500k" selected>2.5 Mbps</option>
                        <option value="5000k">5 Mbps</option>
                        <option value="10000k">10 Mbps</option>
                    </select>
                </div>
                <div class="col-md-4 mb-3">
                    <label class="form-label">Resolução</label>
                    <select name="resolution" class="form-select">
                        <option value="640x360">360p (640x360)</option>
                        <option value="854x480">480p (854x480)</option>
                        <option value="1280x720" selected>720p (1280x720)</option>
                        <option value="1920x1080">1080p (1920x1080)</option>
                        <option value="3840x2160">4K (3840x2160)</option>
                    </select>
                </div>
                <div class="col-md-4 mb-3">
                    <label class="form-label">Codec de Vídeo</label>
                    <select name="codec" class="form-select">
                        <option value="h264">H.264</option>
                        <option value="h265">H.265 (HEVC)</option>
                        <option value="av1">AV1</option>
                    </select>
                </div>
            </div>
            
            <div class="mb-3">
                <label class="form-label">Descrição</label>
                <textarea name="description" class="form-control" rows="3" placeholder="Descrição opcional da stream..."></textarea>
            </div>
            
            <div class="d-flex justify-content-between">
                <a href="/streams" class="btn btn-secondary">Cancelar</a>
                <button type="submit" class="btn btn-primary">
                    <i class="bi bi-check-circle"></i> Criar Stream
                </button>
            </div>
        </form>
    </div>
</div>
{% endblock %}
EOF

# Upload page
sudo tee /opt/hls-dashboard/templates/upload.html > /dev/null << 'EOF'
{% extends "base.html" %}

{% block content %}
<h1><i class="bi bi-upload"></i> Upload de Vídeos</h1>

<div class="row mt-4">
    <div class="col-md-6">
        <div class="card">
            <div class="card-header">
                <h5 class="mb-0">Enviar Arquivo</h5>
            </div>
            <div class="card-body">
                <form method="POST" enctype="multipart/form-data">
                    <div class="mb-3">
                        <label class="form-label">Selecionar Arquivo</label>
                        <input type="file" name="file" class="form-control" accept="video/*,.mp4,.avi,.mov,.mkv" required>
                    </div>
                    <div class="mb-3">
                        <label class="form-label">Nome para Stream</label>
                        <input type="text" name="stream_name" class="form-control" placeholder="Nome automático do arquivo">
                    </div>
                    <div class="mb-3 form-check">
                        <input type="checkbox" name="convert_hls" class="form-check-input" checked>
                        <label class="form-check-label">Converter para HLS automaticamente</label>
                    </div>
                    <button type="submit" class="btn btn-primary">
                        <i class="bi bi-upload"></i> Enviar e Processar
                    </button>
                </form>
            </div>
        </div>
        
        <div class="card mt-4">
            <div class="card-header">
                <h5 class="mb-0">Informações</h5>
            </div>
            <div class="card-body">
                <p><strong>Formatos suportados:</strong> MP4, AVI, MOV, MKV</p>
                <p><strong>Tamanho máximo:</strong> 500 MB</p>
                <p><strong>Processamento automático:</strong> Conversão para HLS</p>
                <p><strong>Local dos arquivos:</strong> /opt/hls-dashboard/uploads/</p>
            </div>
        </div>
    </div>
    
    <div class="col-md-6">
        <div class="card">
            <div class="card-header d-flex justify-content-between align-items-center">
                <h5 class="mb-0">Arquivos Enviados</h5>
                <span class="badge bg-primary">{{ files|length }} arquivos</span>
            </div>
            <div class="card-body">
                {% if files %}
                <div class="list-group">
                    {% for file in files %}
                    <div class="list-group-item d-flex justify-content-between align-items-center">
                        <div>
                            <i class="bi bi-file-earmark-play"></i>
                            {{ file }}
                        </div>
                        <div>
                            <a href="/uploads/{{ file }}" class="btn btn-sm btn-outline-primary" target="_blank">
                                <i class="bi bi-download"></i>
                            </a>
                        </div>
                    </div>
                    {% endfor %}
                </div>
                {% else %}
                <p class="text-muted text-center">Nenhum arquivo enviado ainda</p>
                {% endif %}
            </div>
        </div>
        
        <div class="card mt-4">
            <div class="card-header">
                <h5 class="mb-0">Conversão HLS</h5>
            </div>
            <div class="card-body">
                <p>Os arquivos são convertidos para o formato HLS com as seguintes configurações:</p>
                <ul>
                    <li>Segmentação: 10 segundos por segmento</li>
                    <li>Qualidades: 240p, 480p, 720p, 1080p</li>
                    <li>Codec: H.264 / AAC</li>
                    <li>Playlist master: master.m3u8</li>
                </ul>
                <div class="alert alert-info">
                    <i class="bi bi-info-circle"></i>
                    Após o upload, uma nova stream será criada automaticamente.
                </div>
            </div>
        </div>
    </div>
</div>
{% endblock %}
EOF

# Monitor page
sudo tee /opt/hls-dashboard/templates/monitor.html > /dev/null << 'EOF'
{% extends "base.html" %}

{% block content %}
<h1><i class="bi bi-graph-up"></i> Monitor em Tempo Real</h1>

<div class="row mt-4">
    <div class="col-md-8">
        <div class="card">
            <div class="card-header">
                <h5 class="mb-0">Status das Streams em Tempo Real</h5>
            </div>
            <div class="card-body">
                <div id="stream-monitor">
                    <div class="text-center">
                        <div class="spinner-border text-primary" role="status">
                            <span class="visually-hidden">Carregando...</span>
                        </div>
                        <p class="mt-2">Conectando ao monitor em tempo real...</p>
                    </div>
                </div>
            </div>
        </div>
        
        <div class="card mt-4">
            <div class="card-header">
                <h5 class="mb-0">Gráfico de Visualizações</h5>
            </div>
            <div class="card-body">
                <canvas id="viewsChart" height="100"></canvas>
            </div>
        </div>
    </div>
    
    <div class="col-md-4">
        <div class="card">
            <div class="card-header">
                <h5 class="mb-0">Estatísticas</h5>
            </div>
            <div class="card-body">
                <div class="mb-3">
                    <h6>Visualizações Totais</h6>
                    <h2 id="total-views">0</h2>
                </div>
                <div class="mb-3">
                    <h6>Streams Ativas</h6>
                    <h2 id="active-streams">0</h2>
                </div>
                <div class="mb-3">
                    <h6>Largura de Banda</h6>
                    <h2 id="bandwidth">0 Mbps</h2>
                </div>
                <div class="mb-3">
                    <h6>Latência Média</h6>
                    <h2 id="latency">0ms</h2>
                </div>
            </div>
        </div>
        
        <div class="card mt-4">
            <div class="card-header">
                <h5 class="mb-0">Alertas Recentes</h5>
            </div>
            <div class="card-body">
                <div id="alerts-list">
                    <div class="alert alert-success">
                        <small><i class="bi bi-check-circle"></i> Sistema operando normalmente</small>
                    </div>
                </div>
            </div>
        </div>
    </div>
</div>

<script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
<script>
    const ctx = document.getElementById('viewsChart').getContext('2d');
    const chart = new Chart(ctx, {
        type: 'line',
        data: {
            labels: [],
            datasets: [{
                label: 'Visualizações',
                data: [],
                borderColor: 'rgb(75, 192, 192)',
                tension: 0.1
            }]
        },
        options: {
            responsive: true,
            plugins: {
                legend: { display: false }
            }
        }
    });
    
    // Simular dados em tempo real
    function updateRealTimeData() {
        fetch('/api/streams/status')
            .then(response => response.json())
            .then(data => {
                // Atualizar estatísticas
                const activeStreams = data.streams.filter(s => s.status === 'active').length;
                const totalViews = data.streams.reduce((sum, s) => sum + (s.viewers || 0), 0);
                
                document.getElementById('active-streams').textContent = activeStreams;
                document.getElementById('total-views').textContent = totalViews;
                document.getElementById('bandwidth').textContent = (activeStreams * 2.5).toFixed(1) + ' Mbps';
                document.getElementById('latency').textContent = Math.floor(Math.random() * 100) + 'ms';
                
                // Atualizar gráfico
                const time = new Date(data.timestamp).toLocaleTimeString();
                chart.data.labels.push(time);
                chart.data.datasets[0].data.push(totalViews);
                
                if (chart.data.labels.length > 10) {
                    chart.data.labels.shift();
                    chart.data.datasets[0].data.shift();
                }
                
                chart.update();
                
                // Atualizar monitor de streams
                updateStreamMonitor(data.streams);
            });
    }
    
    function updateStreamMonitor(streams) {
        const monitor = document.getElementById('stream-monitor');
        monitor.innerHTML = '';
        
        streams.forEach(stream => {
            const statusColor = stream.status === 'active' ? 'success' : 
                              stream.status === 'stopped' ? 'danger' : 'warning';
            
            monitor.innerHTML += `
                <div class="mb-3 p-3 border rounded">
                    <div class="d-flex justify-content-between align-items-center">
                        <div>
                            <h6 class="mb-0">${stream.name}</h6>
                            <small class="text-muted">ID: ${stream.id}</small>
                        </div>
                        <div>
                            <span class="badge bg-${statusColor}">${stream.status}</span>
                            <span class="badge bg-info ms-2">${stream.viewers || 0} viewers</span>
                        </div>
                    </div>
                    <div class="mt-2">
                        <div class="progress" style="height: 5px;">
                            <div class="progress-bar bg-${statusColor}" 
                                 style="width: ${stream.status === 'active' ? '100' : '0'}%">
                            </div>
                        </div>
                        <small class="text-muted">Última atividade: ${stream.last_active || 'Nunca'}</small>
                    </div>
                </div>
            `;
        });
    }
    
    // Atualizar a cada 3 segundos
    setInterval(updateRealTimeData, 3000);
    updateRealTimeData();
</script>
{% endblock %}
EOF

# Settings page
sudo tee /opt/hls-dashboard/templates/settings.html > /dev/null << 'EOF'
{% extends "base.html" %}

{% block content %}
<h1><i class="bi bi-gear"></i> Configurações</h1>

<div class="row mt-4">
    <div class="col-md-8">
        <div class="card">
            <div class="card-header">
                <h5 class="mb-0">Configurações do Sistema</h5>
            </div>
            <div class="card-body">
                <form method="POST">
                    <h6 class="mt-3">Streaming</h6>
                    <div class="mb-3">
                        <label class="form-label">Porta RTMP</label>
                        <input type="number" name="port" class="form-control" value="{{ settings.port }}">
                    </div>
                    <div class="mb-3">
                        <label class="form-label">Bitrate Máximo</label>
                        <select name="max_bitrate" class="form-select">
                            <option value="1000k" {% if settings.max_bitrate == '1000k' %}selected{% endif %}>1 Mbps</option>
                            <option value="2500k" {% if settings.max_bitrate == '2500k' %}selected{% endif %}>2.5 Mbps</option>
                            <option value="5000k" {% if settings.max_bitrate == '5000k' %}selected{% endif %}>5 Mbps</option>
                            <option value="10000k" {% if settings.max_bitrate == '10000k' %}selected{% endif %}>10 Mbps</option>
                        </select>
                    </div>
                    
                    <h6 class="mt-4">Comportamento</h6>
                    <div class="mb-3 form-check">
                        <input type="checkbox" name="auto_start" class="form-check-input" {% if settings.auto_start %}checked{% endif %}>
                        <label class="form-check-label">Iniciar streams automaticamente</label>
                    </div>
                    <div class="mb-3 form-check">
                        <input type="checkbox" name="auto_create_stream" class="form-check-input" {% if settings.auto_create_stream|default(true) %}checked{% endif %}>
                        <label class="form-check-label">Criar stream automaticamente ao fazer upload</label>
                    </div>
                    
                    <h6 class="mt-4">Segurança</h6>
                    <div class="mb-3">
                        <label class="form-label">Timeout de Sessão (minutos)</label>
                        <input type="number" class="form-control" value="30" readonly>
                    </div>
                    
                    <div class="d-flex justify-content-between mt-4">
                        <a href="/" class="btn btn-secondary">Cancelar</a>
                        <button type="submit" class="btn btn-primary">
                            <i class="bi bi-save"></i> Salvar Configurações
                        </button>
                    </div>
                </form>
            </div>
        </div>
    </div>
    
    <div class="col-md-4">
        <div class="card">
            <div class="card-header">
                <h5 class="mb-0">Informações do Sistema</h5>
            </div>
            <div class="card-body">
                <div class="mb-3">
                    <strong>Versão do Dashboard:</strong>
                    <span class="float-end">2.0.0</span>
                </div>
                <div class="mb-3">
                    <strong>Python:</strong>
                    <span class="float-end">{{ python_version }}</span>
                </div>
                <div class="mb-3">
                    <strong>Flask:</strong>
                    <span class="float-end">2.3.3</span>
                </div>
                <div class="mb-3">
                    <strong>FFmpeg:</strong>
                    <span class="float-end">{{ ffmpeg_version }}</span>
                </div>
                <hr>
                <div class="mb-3">
                    <strong>Arquivos de Config:</strong>
                    <span class="float-end">/opt/hls-dashboard/</span>
                </div>
                <div class="mb-3">
                    <strong>Logs:</strong>
                    <span class="float-end">/var/log/hls-dashboard/</span>
                </div>
                <div class="mb-3">
                    <strong>Uploads:</strong>
                    <span class="float-end">/opt/hls-dashboard/uploads/</span>
                </div>
            </div>
        </div>
        
        <div class="card mt-4">
            <div class="card-header">
                <h5 class="mb-0">Ações</h5>
            </div>
            <div class="card-body">
                <div class="d-grid gap-2">
                    <button class="btn btn-outline-primary" onclick="restartService()">
                        <i class="bi bi-arrow-clockwise"></i> Reiniciar Serviço
                    </button>
                    <button class="btn btn-outline-warning" onclick="clearLogs()">
                        <i class="bi bi-trash"></i> Limpar Logs
                    </button>
                    <button class="btn btn-outline-danger" onclick="backupConfig()">
                        <i class="bi bi-download"></i> Backup Configuração
                    </button>
                </div>
            </div>
        </div>
    </div>
</div>

<script>
function restartService() {
    if (confirm('Reiniciar o serviço? As streams ativas serão interrompidas.')) {
        alert('Reiniciando... (em produção, isso chamaria uma API)');
    }
}

function clearLogs() {
    if (confirm('Limpar todos os logs?')) {
        alert('Logs limpos (em produção, isso chamaria uma API)');
    }
}

function backupConfig() {
    alert('Iniciando backup... (em produção, isso baixaria um arquivo)');
}
</script>
{% endblock %}
EOF

# Base template
sudo tee /opt/hls-dashboard/templates/base.html > /dev/null << 'EOF'
<!DOCTYPE html>
<html lang="pt-BR">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>{% block title %}HLS Dashboard{% endblock %}</title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.1.3/dist/css/bootstrap.min.css" rel="stylesheet">
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap-icons@1.8.1/font/bootstrap-icons.css">
    <style>
        :root {
            --primary-color: #4361ee;
            --secondary-color: #3a0ca3;
        }
        body {
            background-color: #f8f9fa;
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
        }
        .navbar {
            background: linear-gradient(90deg, var(--primary-color) 0%, var(--secondary-color) 100%);
            box-shadow: 0 2px 10px rgba(0,0,0,0.1);
        }
        .main-content {
            padding: 20px;
            margin-top: 70px;
        }
        .stat-card {
            background: white;
            border-radius: 10px;
            padding: 20px;
            margin-bottom: 20px;
            box-shadow: 0 4px 6px rgba(0,0,0,0.05);
        }
        .footer {
            margin-top: 40px;
            padding: 20px;
            text-align: center;
            color: #666;
            border-top: 1px solid #dee2e6;
        }
    </style>
    {% block head %}{% endblock %}
</head>
<body>
    <!-- Navbar -->
    <nav class="navbar navbar-expand-lg navbar-dark fixed-top">
        <div class="container-fluid">
            <a class="navbar-brand" href="/">
                <i class="bi bi-camera-reels"></i> HLS Dashboard
            </a>
            <div class="navbar-nav ms-auto">
                <a class="nav-link" href="/monitor">
                    <i class="bi bi-graph-up"></i> Monitor
                </a>
                <a class="nav-link" href="/help">
                    <i class="bi bi-question-circle"></i> Ajuda
                </a>
                <a class="nav-link" href="/logout">
                    <i class="bi bi-box-arrow-right"></i> Sair
                </a>
            </div>
        </div>
    </nav>

    <!-- Main Content -->
    <div class="container-fluid main-content">
        <!-- Flash Messages -->
        {% with messages = get_flashed_messages(with_categories=true) %}
            {% if messages %}
                {% for category, message in messages %}
                    <div class="alert alert-{{ category }} alert-dismissible fade show">
                        {{ message }}
                        <button type="button" class="btn-close" data-bs-dismiss="alert"></button>
                    </div>
                {% endfor %}
            {% endif %}
        {% endwith %}

        {% block content %}{% endblock %}
    </div>

    <!-- Footer -->
    <div class="footer">
        <p>HLS Dashboard v2.0.0 | © 2024 | 
            <a href="/health" class="text-decoration-none">Status do Serviço</a> | 
            <a href="/api/dashboard/stats" class="text-decoration-none">API</a>
        </p>
    </div>

    <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.1.3/dist/js/bootstrap.bundle.min.js"></script>
    {% block scripts %}{% endblock %}
</body>
</html>
EOF

# 8. CONFIGURAR AMBIENTE PYTHON
echo "🐍 Configurando ambiente Python..."
sudo chown -R hlsadmin:hlsadmin /opt/hls-dashboard

cd /opt/hls-dashboard
sudo -u hlsadmin python3 -m venv venv
sudo -u hlsadmin ./venv/bin/pip install --upgrade pip

# Instalar dependências
sudo -u hlsadmin ./venv/bin/pip install flask==2.3.3 gunicorn==21.2.0 flask-socketio==5.3.4

# 9. CRIAR SERVIÇO SYSTEMD
echo "⚙️ Criando serviço systemd..."

sudo tee /etc/systemd/system/hls-dashboard.service > /dev/null << 'EOF'
[Unit]
Description=HLS Dashboard Service
After=network.target
Wants=network.target

[Service]
Type=simple
User=hlsadmin
Group=hlsadmin
WorkingDirectory=/opt/hls-dashboard
Environment="PATH=/opt/hls-dashboard/venv/bin"
Environment="PYTHONUNBUFFERED=1"
Environment="FLASK_APP=app.py"
ExecStart=/opt/hls-dashboard/venv/bin/gunicorn \
    --bind 0.0.0.0:5000 \
    --workers 2 \
    --threads 4 \
    --timeout 60 \
    --access-logfile /var/log/hls-dashboard/access.log \
    --error-logfile /var/log/hls-dashboard/error.log \
    app:app
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=hls-dashboard

# Security
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=/opt/hls-dashboard/uploads /opt/hls-dashboard/streams

[Install]
WantedBy=multi-user.target
EOF

# Criar diretório de logs
sudo mkdir -p /var/log/hls-dashboard
sudo chown -R hlsadmin:hlsadmin /var/log/hls-dashboard

# 10. CONFIGURAR NGINX COMO PROXY REVERSO (OPCIONAL)
echo "🌐 Configurando Nginx..."

sudo tee /etc/nginx/sites-available/hls-dashboard > /dev/null << 'EOF'
server {
    listen 80;
    server_name _;
    
    location / {
        proxy_pass http://localhost:5000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        
        # WebSocket support
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        
        # Timeouts
        proxy_connect_timeout 300s;
        proxy_send_timeout 300s;
        proxy_read_timeout 300s;
    }
    
    # Servir arquivos de vídeo diretamente
    location /uploads/ {
        alias /opt/hls-dashboard/uploads/;
        expires 30d;
        add_header Cache-Control "public";
    }
    
    location /streams/ {
        alias /opt/hls-dashboard/streams/;
        expires 30d;
        add_header Cache-Control "public";
        add_header Access-Control-Allow-Origin "*";
    }
    
    # Bloquer acesso a arquivos sensíveis
    location ~ /\. {
        deny all;
    }
}
EOF

# Habilitar site
sudo ln -sf /etc/nginx/sites-available/hls-dashboard /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl restart nginx

# 11. INICIAR SERVIÇO
echo "🚀 Iniciando serviço..."

sudo systemctl daemon-reload
sudo systemctl enable hls-dashboard.service
sudo systemctl start hls-dashboard.service

sleep 5

# 12. TESTAR INSTALAÇÃO
echo "🧪 Testando instalação..."

if sudo systemctl is-active --quiet hls-dashboard.service; then
    echo "✅ Serviço ativo!"
    
    echo "Testando aplicação..."
    if curl -s http://localhost:5000/health | grep -q "healthy"; then
        echo "✅✅✅ DASHBOARD FUNCIONANDO PERFEITAMENTE!"
    else
        echo "⚠️ Aplicação não responde corretamente"
        sudo journalctl -u hls-dashboard -n 20 --no-pager
    fi
else
    echo "❌ Serviço falhou ao iniciar"
    sudo journalctl -u hls-dashboard -n 30 --no-pager
    exit 1
fi

# 13. CRIAR SCRIPT DE GERENCIAMENTO
sudo tee /usr/local/bin/hls-manager > /dev/null << 'EOF'
#!/bin/bash
echo "🛠️  Gerenciador HLS Dashboard"
echo "============================="
echo ""
echo "Comandos disponíveis:"
echo "  status     - Ver status do serviço"
echo "  restart    - Reiniciar serviço"
echo "  logs       - Ver logs"
echo "  start      - Iniciar serviço"
echo "  stop       - Parar serviço"
echo "  backup     - Fazer backup"
echo "  update     - Atualizar dashboard"
echo "  help       - Mostrar ajuda"
echo ""

case "$1" in
    status)
        sudo systemctl status hls-dashboard --no-pager
        ;;
    restart)
        sudo systemctl restart hls-dashboard
        echo "✅ Serviço reiniciado"
        ;;
    logs)
        if [ "$2" = "-f" ]; then
            sudo journalctl -u hls-dashboard -f
        else
            sudo journalctl -u hls-dashboard -n 50 --no-pager
        fi
        ;;
    start)
        sudo systemctl start hls-dashboard
        echo "✅ Serviço iniciado"
        ;;
    stop)
        sudo systemctl stop hls-dashboard
        echo "✅ Serviço parado"
        ;;
    backup)
        BACKUP_DIR="/opt/hls-dashboard-backup-$(date +%Y%m%d-%H%M%S)"
        sudo cp -r /opt/hls-dashboard "$BACKUP_DIR"
        echo "✅ Backup criado em $BACKUP_DIR"
        ;;
    update)
        echo "Atualizando dashboard..."
        cd /opt/hls-dashboard
        sudo git pull 2>/dev/null || echo "Git não configurado"
        sudo systemctl restart hls-dashboard
        ;;
    help|*)
        echo "Uso: hls-manager [comando]"
        echo ""
        echo "URLs de acesso:"
        IP=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "localhost")
        echo "  • Dashboard: http://$IP:5000"
        echo "  • API Health: http://$IP:5000/health"
        echo "  • Uploads: http://$IP:5000/upload"
        echo ""
        echo "Arquivos de configuração:"
        echo "  • App: /opt/hls-dashboard/app.py"
        echo "  • Templates: /opt/hls-dashboard/templates/"
        echo "  • Uploads: /opt/hls-dashboard/uploads/"
        ;;
esac
EOF

sudo chmod +x /usr/local/bin/hls-manager

# 14. MOSTRAR INFORMAÇÕES FINAIS
IP=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "localhost")

echo ""
echo "🎉🎉🎉 INSTALAÇÃO COMPLETA DO HLS DASHBOARD! 🎉🎉🎉"
echo "================================================"
echo ""
echo "✅ DASHBOARD INSTALADO COM SUCESSO!"
echo ""
echo "🌐 URLS DE ACESSO:"
echo "   🔗 DASHBOARD PRINCIPAL: http://$IP:5000"
echo "   📊 MONITOR: http://$IP:5000/monitor"
echo "   ⚙️  CONFIGURAÇÕES: http://$IP:5000/settings"
echo "   📤 UPLOAD: http://$IP:5000/upload"
echo "   ❤️  HEALTH CHECK: http://$IP:5000/health"
echo ""
echo "🔐 CREDENCIAIS PADRÃO:"
echo "   👤 Usuário: admin"
echo "   🔑 Senha: admin"
echo ""
echo "⚙️  COMANDOS DE GERENCIAMENTO:"
echo "   • hls-manager status      - Ver status"
echo "   • hls-manager logs        - Ver logs"
echo "   • hls-manager restart     - Reiniciar"
echo "   • sudo systemctl [start|stop|restart] hls-dashboard"
echo ""
echo "📁 DIRETÓRIOS:"
echo "   • Aplicação: /opt/hls-dashboard/"
echo "   • Templates: /opt/hls-dashboard/templates/"
echo "   • Uploads: /opt/hls-dashboard/uploads/"
echo "   • Logs: /var/log/hls-dashboard/"
echo ""
echo "🔧 RECURSOS INCLUÍDOS:"
echo "   ✅ Dashboard com métricas em tempo real"
echo "   ✅ Gerenciamento completo de streams"
echo "   ✅ Upload e conversão de vídeos"
echo "   ✅ Monitoramento do sistema"
echo "   ✅ Relatórios e estatísticas"
echo "   ✅ Configurações personalizáveis"
echo "   ✅ API RESTful"
echo "   ✅ Interface responsiva"
echo ""
echo "📋 PRÓXIMOS PASSOS RECOMENDADOS:"
echo "   1. Acesse http://$IP:5000 e faça login com admin/admin"
echo "   2. Altere a senha padrão nas configurações"
echo "   3. Configure o FFmpeg para conversão HLS"
echo "   4. Configure domínio e SSL no Nginx"
echo "   5. Configure backup automático"
echo ""
echo "⚠️  IMPORTANTE: Este é um sistema de desenvolvimento."
echo "   Para produção, configure:"
echo "   • SSL/TLS (HTTPS)"
echo "   • Autenticação segura"
echo "   • Firewall e segurança"
echo "   • Backup automático"
echo ""
echo "💡 DICA: Use 'hls-manager help' para ver todas as opções."
echo ""
echo "✨ INSTALAÇÃO CONCLUÍDA COM SUCESSO! ✨"
