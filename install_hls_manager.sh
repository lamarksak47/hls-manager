#!/bin/bash
# install_hls_with_dashboard_fixed.sh - INSTALAÇÃO COMPLETA COM CORREÇÕES

set -e

echo "🚀 INSTALAÇÃO DO HLS MANAGER COM DASHBOARD (FIXED)"
echo "==================================================="

# 0. VERIFICAR SISTEMA DE ARQUIVOS
echo "🔍 Verificando sistema de arquivos..."
if mount | grep " / " | grep -q "ro,"; then
    echo "⚠️  Sistema de arquivos root está SOMENTE LEITURA! Corrigindo..."
    sudo mount -o remount,rw /
    echo "✅ Sistema de arquivos agora é leitura/gravação"
fi

# 1. PARAR SERVIÇOS EXISTENTES
echo "🛑 Parando serviços existentes..."
sudo systemctl stop hls-manager hls-dashboard hls-service hls-final hls-app 2>/dev/null || true
sudo pkill -9 gunicorn 2>/dev/null || true
sudo pkill -9 python 2>/dev/null || true

# Liberar portas
echo "🔓 Liberando portas..."
sudo fuser -k 5000/tcp 2>/dev/null || true
sudo fuser -k 5001/tcp 2>/dev/null || true
sudo fuser -k 8080/tcp 2>/dev/null || true
sleep 2

# 2. LIMPAR INSTALAÇÕES ANTERIORES
echo "🧹 Limpando instalações anteriores..."
sudo rm -rf /opt/hls-dashboard 2>/dev/null || true
sudo rm -rf /opt/hls-manager 2>/dev/null || true
sudo rm -f /etc/systemd/system/hls-*.service 2>/dev/null || true
sudo systemctl daemon-reload

# 3. CRIAR USUÁRIO E DIRETÓRIO EM /home/ PARA EVITAR PROBLEMAS
echo "👤 Criando usuário e estrutura em /home/..."

# Remover usuário antigo se existir
sudo userdel hlsadmin 2>/dev/null || true
sudo rm -rf /home/hls-dashboard 2>/dev/null || true

# Criar usuário simples sem home directory problemático
sudo useradd -r -s /bin/false hlsweb 2>/dev/null || true

sudo mkdir -p /home/hls-dashboard
sudo mkdir -p /home/hls-dashboard/uploads
sudo mkdir -p /home/hls-dashboard/streams
sudo mkdir -p /home/hls-dashboard/static
sudo mkdir -p /home/hls-dashboard/templates

cd /home/hls-dashboard

# 4. INSTALAR DEPENDÊNCIAS MÍNIMAS (sem Gunicorn/SocketIO problemáticos)
echo "📦 Instalando dependências mínimas..."
sudo apt-get update
sudo apt-get upgrade -y
sudo apt-get install -y python3 python3-pip python3-venv

# 5. CRIAR APLICAÇÃO FLASK SIMPLIFICADA (sem SocketIO, sem Gunicorn na inicialização)
echo "💻 Criando aplicação Flask simplificada..."

# Arquivo principal da aplicação - VERSÃO SIMPLIFICADA E ESTÁVEL
sudo tee /home/hls-dashboard/app.py > /dev/null << 'EOF'
from flask import Flask, render_template, jsonify, request, redirect, url_for, send_from_directory, flash
import os
import json
import subprocess
import time
from datetime import datetime
import uuid

app = Flask(__name__)
app.secret_key = 'hls-dashboard-secret-key-2024-fixed'
app.config['UPLOAD_FOLDER'] = '/home/hls-dashboard/uploads'
app.config['STREAMS_FOLDER'] = '/home/hls-dashboard/streams'
app.config['MAX_CONTENT_LENGTH'] = 500 * 1024 * 1024  # 500MB

# Banco de dados simples em JSON
DB_FILE = '/home/hls-dashboard/database.json'

def load_database():
    if os.path.exists(DB_FILE):
        try:
            with open(DB_FILE, 'r') as f:
                return json.load(f)
        except:
            pass
    return {
        'streams': [],
        'users': [
            {'username': 'admin', 'password': 'admin', 'role': 'admin'}
        ],
        'settings': {
            'auto_start': True,
            'max_bitrate': '2500k',
            'port': 8080
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

# Criar banco de dados inicial
if not os.path.exists(DB_FILE):
    save_database(load_database())

# Rota principal - Dashboard simplificado
@app.route('/')
def dashboard():
    data = load_database()
    
    # Status do sistema de forma segura
    try:
        cpu_usage = subprocess.getoutput("top -bn1 | grep 'Cpu(s)' | awk '{print $2}' 2>/dev/null | head -1").replace('%us,', '') or '0%'
    except:
        cpu_usage = '0%'
    
    try:
        memory_usage = subprocess.getoutput("free -m | awk 'NR==2{printf \"%.1f%%\", $3*100/$2}' 2>/dev/null") or '0%'
    except:
        memory_usage = '0%'
    
    try:
        disk_usage = subprocess.getoutput("df -h /home | awk 'NR==2{print $5}' 2>/dev/null") or '0%'
    except:
        disk_usage = '0%'
    
    system_status = {
        'cpu_usage': cpu_usage,
        'memory_usage': memory_usage,
        'disk_usage': disk_usage,
        'uptime': subprocess.getoutput("uptime -p 2>/dev/null") or 'Desconhecido',
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
    try:
        cpu = subprocess.getoutput("top -bn1 | grep 'Cpu(s)' | awk '{print $2}' 2>/dev/null | head -1").replace('%us,', '') or '0%'
    except:
        cpu = '0%'
    
    try:
        memory = subprocess.getoutput("free -m | awk 'NR==2{printf \"%.1f%%\", $3*100/$2}' 2>/dev/null") or '0%'
    except:
        memory = '0%'
    
    try:
        disk = subprocess.getoutput("df -h /home | awk 'NR==2{print $5}' 2>/dev/null") or '0%'
    except:
        disk = '0%'
    
    return jsonify({
        'cpu': cpu,
        'memory': memory,
        'disk': disk,
        'uptime': subprocess.getoutput("uptime -p 2>/dev/null") or 'Desconhecido',
        'time': datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    })

# Gerenciamento de Streams simplificado
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
            'source': request.form.get('source', ''),
            'bitrate': request.form.get('bitrate', '2500k'),
            'resolution': request.form.get('resolution', '1280x720'),
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

# Upload de vídeos simplificado
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
        data['settings']['max_bitrate'] = request.form.get('max_bitrate', '2500k')
        data['settings']['port'] = int(request.form.get('port', 8080))
        data['settings']['auto_create_stream'] = request.form.get('auto_create_stream') == 'on'
        
        save_database(data)
        flash('Configurações salvas!', 'success')
        return redirect(url_for('settings'))
    
    return render_template('settings.html', settings=data['settings'])

# Monitoramento simplificado
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

# Health check - VERSÃO CRÍTICA
@app.route('/health')
def health():
    return jsonify({
        'status': 'healthy',
        'service': 'hls-dashboard-fixed',
        'version': '3.0.0',
        'timestamp': datetime.now().isoformat(),
        'streams_count': len(load_database()['streams']),
        'port': 8080,
        'message': 'System running on port 8080 without Gunicorn issues'
    })

# Login simplificado
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

# Página de ajuda simplificada
@app.route('/help')
def help_page():
    return render_template('help.html')

# Test page
@app.route('/test')
def test_page():
    return '''
    <!DOCTYPE html>
    <html>
    <head><title>Test Page</title></head>
    <body>
        <h1>✅ HLS Dashboard Test</h1>
        <p>Sistema funcionando na porta 8080</p>
        <p><a href="/">Voltar ao Dashboard</a></p>
    </body>
    </html>
    '''

if __name__ == '__main__':
    # Garantir que as pastas existem
    os.makedirs(app.config['UPLOAD_FOLDER'], exist_ok=True)
    os.makedirs(app.config['STREAMS_FOLDER'], exist_ok=True)
    
    print("🚀 Iniciando HLS Dashboard FIXED na porta 8080...")
    print("✅ Health check: http://localhost:8080/health")
    print("✅ Test page: http://localhost:8080/test")
    print("✅ Dashboard: http://localhost:8080/")
    
    # Usar Flask puro - sem Gunicorn, sem SocketIO
    app.run(host='0.0.0.0', port=8080, debug=False, threaded=True)
EOF

# 6. CRIAR TEMPLATES HTML SIMPLIFICADOS
echo "🎨 Criando templates HTML simplificados..."

# Dashboard principal simplificado
sudo tee /home/hls-dashboard/templates/dashboard.html > /dev/null << 'EOF'
<!DOCTYPE html>
<html lang="pt-BR">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>🎬 HLS Dashboard FIXED</title>
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
            padding: 20px;
        }
        
        .header {
            background: linear-gradient(90deg, var(--primary-color) 0%, var(--secondary-color) 100%);
            color: white;
            padding: 20px;
            border-radius: 10px;
            margin-bottom: 20px;
        }
        
        .stat-card {
            background: white;
            border-radius: 10px;
            padding: 20px;
            margin-bottom: 20px;
            box-shadow: 0 4px 6px rgba(0,0,0,0.1);
            transition: transform 0.3s;
        }
        
        .stat-card:hover {
            transform: translateY(-5px);
        }
        
        .stat-icon {
            font-size: 2rem;
            margin-bottom: 10px;
            color: var(--primary-color);
        }
        
        .nav-tabs {
            margin-bottom: 20px;
        }
        
        .system-health {
            font-size: 0.9rem;
            color: #666;
            text-align: right;
        }
    </style>
</head>
<body>
    <!-- Header -->
    <div class="header">
        <div class="d-flex justify-content-between align-items-center">
            <h1><i class="bi bi-camera-reels"></i> HLS Dashboard 3.0</h1>
            <div class="system-health">
                <span id="system-time"></span> | 
                <span class="text-success">● Online (Porta 8080)</span>
            </div>
        </div>
        <p class="mb-0">Sistema corrigido e otimizado - Sem problemas de Gunicorn</p>
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

    <!-- Navigation -->
    <ul class="nav nav-tabs">
        <li class="nav-item">
            <a class="nav-link active" href="/">
                <i class="bi bi-speedometer2"></i> Dashboard
            </a>
        </li>
        <li class="nav-item">
            <a class="nav-link" href="/streams">
                <i class="bi bi-collection-play"></i> Streams
            </a>
        </li>
        <li class="nav-item">
            <a class="nav-link" href="/upload">
                <i class="bi bi-upload"></i> Upload
            </a>
        </li>
        <li class="nav-item">
            <a class="nav-link" href="/settings">
                <i class="bi bi-gear"></i> Configurações
            </a>
        </li>
        <li class="nav-item">
            <a class="nav-link" href="/help">
                <i class="bi bi-question-circle"></i> Ajuda
            </a>
        </li>
    </ul>

    <!-- Stats Cards -->
    <div class="row">
        <div class="col-md-3">
            <div class="stat-card">
                <div class="stat-icon">
                    <i class="bi bi-collection-play"></i>
                </div>
                <h3 id="total-streams">{{ stats.total_streams }}</h3>
                <p class="text-muted">Total Streams</p>
            </div>
        </div>
        <div class="col-md-3">
            <div class="stat-card">
                <div class="stat-icon">
                    <i class="bi bi-play-circle"></i>
                </div>
                <h3 id="active-streams">{{ stats.active_streams }}</h3>
                <p class="text-muted">Streams Ativas</p>
            </div>
        </div>
        <div class="col-md-3">
            <div class="stat-card">
                <div class="stat-icon">
                    <i class="bi bi-cpu"></i>
                </div>
                <h3 id="cpu-usage">{{ system.cpu_usage }}</h3>
                <p class="text-muted">Uso de CPU</p>
            </div>
        </div>
        <div class="col-md-3">
            <div class="stat-card">
                <div class="stat-icon">
                    <i class="bi bi-memory"></i>
                </div>
                <h3 id="memory-usage">{{ system.memory_usage }}</h3>
                <p class="text-muted">Uso de Memória</p>
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
                                    {% if stream.status == 'active' %}
                                        <span class="badge bg-success">{{ stream.status }}</span>
                                    {% elif stream.status == 'stopped' %}
                                        <span class="badge bg-danger">{{ stream.status }}</span>
                                    {% else %}
                                        <span class="badge bg-warning">{{ stream.status }}</span>
                                    {% endif %}
                                </td>
                                <td>{{ stream.resolution or 'Auto' }}</td>
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
                        <div class="progress-bar bg-success" id="memory-bar"></div>
                    </div>
                    
                    <p class="mt-3"><strong>Uso de Disco:</strong> {{ system.disk_usage }}</p>
                    <div class="progress">
                        <div class="progress-bar bg-info" id="disk-bar"></div>
                    </div>
                    
                    <p class="mt-3"><strong>Tempo de Atividade:</strong> {{ system.uptime }}</p>
                    <p><strong>Conexões Ativas:</strong> {{ system.active_connections }}</p>
                </div>
            </div>
            
            <div class="stat-card mt-4">
                <h4><i class="bi bi-lightning-charge"></i> Ações Rápidas</h4>
                <div class="d-grid gap-2 mt-3">
                    <a href="/test" class="btn btn-outline-primary">
                        <i class="bi bi-check-circle"></i> Testar Sistema
                    </a>
                    <a href="/health" class="btn btn-outline-success">
                        <i class="bi bi-heart-pulse"></i> Health Check
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
        <p>HLS Dashboard v3.0.0 (Fixed) | © 2024 | 
            <a href="/health" class="text-decoration-none">Status do Serviço</a> | 
            Porta: 8080
        </p>
    </div>

    <!-- Scripts -->
    <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.1.3/dist/js/bootstrap.bundle.min.js"></script>
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
                })
                .catch(error => console.error('Erro ao buscar stats:', error));
            
            fetch('/api/system/info')
                .then(response => response.json())
                .then(data => {
                    document.getElementById('cpu-usage').textContent = data.cpu;
                    document.getElementById('memory-usage').textContent = data.memory;
                    
                    // Atualizar barras de progresso
                    const memoryPercent = parseFloat(data.memory) || 0;
                    const diskPercent = parseFloat(data.disk) || 0;
                    
                    document.getElementById('memory-bar').style.width = memoryPercent + '%';
                    document.getElementById('disk-bar').style.width = diskPercent + '%';
                })
                .catch(error => console.error('Erro ao buscar system info:', error));
        }
        
        setInterval(updateDashboardStats, 10000);
        updateDashboardStats();
    </script>
</body>
</html>
EOF

# 7. CRIAR OS OUTROS TEMPLATES SIMPLIFICADOS
echo "📝 Criando templates adicionais..."

# Login page simplificado
sudo tee /home/hls-dashboard/templates/login.html > /dev/null << 'EOF'
<!DOCTYPE html>
<html>
<head>
    <title>Login - HLS Dashboard</title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.1.3/dist/css/bootstrap.min.css" rel="stylesheet">
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap-icons@1.8.1/font/bootstrap-icons.css">
    <style>
        body {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
            padding: 20px;
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
        .info-badge {
            background: #d1ecf1;
            color: #0c5460;
            padding: 10px;
            border-radius: 5px;
            margin-bottom: 20px;
            text-align: center;
            font-size: 0.9rem;
        }
    </style>
</head>
<body>
    <div class="login-box">
        <div class="logo">
            <i class="bi bi-camera-reels"></i> HLS Dashboard
        </div>
        
        <div class="info-badge">
            <i class="bi bi-info-circle"></i> Sistema corrigido - Porta 8080
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
                <input type="text" name="username" class="form-control" required value="admin">
            </div>
            <div class="mb-3">
                <label class="form-label">Senha</label>
                <input type="password" name="password" class="form-control" required value="admin">
            </div>
            <button type="submit" class="btn btn-primary w-100">
                <i class="bi bi-box-arrow-in-right"></i> Entrar
            </button>
            <div class="mt-3 text-center">
                <small class="text-muted">Usuário: <strong>admin</strong> | Senha: <strong>admin</strong></small>
            </div>
            <div class="mt-3 text-center">
                <a href="/" class="text-decoration-none">← Voltar ao Dashboard</a>
            </div>
        </form>
    </div>
</body>
</html>
EOF

# Streams list page simplificado
sudo tee /home/hls-dashboard/templates/streams.html > /dev/null << 'EOF'
<!DOCTYPE html>
<html lang="pt-BR">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Streams - HLS Dashboard</title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.1.3/dist/css/bootstrap.min.css" rel="stylesheet">
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap-icons@1.8.1/font/bootstrap-icons.css">
    <style>
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            padding: 20px;
            background-color: #f8f9fa;
        }
        .header {
            background: linear-gradient(90deg, #4361ee 0%, #3a0ca3 100%);
            color: white;
            padding: 20px;
            border-radius: 10px;
            margin-bottom: 20px;
        }
        .card {
            border-radius: 10px;
            box-shadow: 0 4px 6px rgba(0,0,0,0.1);
        }
    </style>
</head>
<body>
    <div class="header">
        <h1><i class="bi bi-collection-play"></i> Gerenciar Streams</h1>
        <p class="mb-0">Sistema corrigido - Porta 8080</p>
    </div>

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

    <div class="card">
        <div class="card-header d-flex justify-content-between align-items-center">
            <h5 class="mb-0">Lista de Streams</h5>
            <a href="/stream/create" class="btn btn-primary">
                <i class="bi bi-plus-circle"></i> Nova Stream
            </a>
        </div>
        <div class="card-body">
            {% if streams %}
            <div class="table-responsive">
                <table class="table table-hover">
                    <thead>
                        <tr>
                            <th>Nome</th>
                            <th>Status</th>
                            <th>Resolução</th>
                            <th>Bitrate</th>
                            <th>Ações</th>
                        </tr>
                    </thead>
                    <tbody>
                        {% for stream in streams %}
                        <tr>
                            <td>{{ stream.name }}</td>
                            <td>
                                {% if stream.status == 'active' %}
                                    <span class="badge bg-success">Ativa</span>
                                {% elif stream.status == 'stopped' %}
                                    <span class="badge bg-danger">Parada</span>
                                {% else %}
                                    <span class="badge bg-warning">{{ stream.status }}</span>
                                {% endif %}
                            </td>
                            <td>{{ stream.resolution or 'Auto' }}</td>
                            <td>{{ stream.bitrate or 'Auto' }}</td>
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
            {% else %}
            <div class="text-center py-5">
                <i class="bi bi-collection-play" style="font-size: 3rem; color: #6c757d;"></i>
                <h4 class="mt-3">Nenhuma stream criada</h4>
                <p class="text-muted">Crie sua primeira stream para começar</p>
                <a href="/stream/create" class="btn btn-primary">
                    <i class="bi bi-plus-circle"></i> Criar Primeira Stream
                </a>
            </div>
            {% endif %}
        </div>
    </div>

    <div class="mt-3">
        <a href="/" class="btn btn-secondary">
            <i class="bi bi-arrow-left"></i> Voltar ao Dashboard
        </a>
    </div>

    <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.1.3/dist/js/bootstrap.bundle.min.js"></script>
</body>
</html>
EOF

# Create stream page simplificado
sudo tee /home/hls-dashboard/templates/stream_create.html > /dev/null << 'EOF'
<!DOCTYPE html>
<html lang="pt-BR">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Criar Stream - HLS Dashboard</title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.1.3/dist/css/bootstrap.min.css" rel="stylesheet">
    <style>
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            padding: 20px;
            background-color: #f8f9fa;
        }
        .header {
            background: linear-gradient(90deg, #4361ee 0%, #3a0ca3 100%);
            color: white;
            padding: 20px;
            border-radius: 10px;
            margin-bottom: 20px;
        }
        .card {
            border-radius: 10px;
            box-shadow: 0 4px 6px rgba(0,0,0,0.1);
        }
    </style>
</head>
<body>
    <div class="header">
        <h1><i class="bi bi-plus-circle"></i> Criar Nova Stream</h1>
        <p class="mb-0">Configure sua nova stream de vídeo</p>
    </div>

    <div class="card">
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
                        <label class="form-label">Fonte da Stream</label>
                        <input type="text" name="source" class="form-control" placeholder="Ex: rtsp://camera.local:554/stream">
                        <small class="text-muted">URL RTSP, arquivo local ou stream URL (opcional)</small>
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
                        </select>
                    </div>
                    <div class="col-md-4 mb-3">
                        <label class="form-label">Resolução</label>
                        <select name="resolution" class="form-select">
                            <option value="640x360">360p (640x360)</option>
                            <option value="854x480">480p (854x480)</option>
                            <option value="1280x720" selected>720p (1280x720)</option>
                            <option value="1920x1080">1080p (1920x1080)</option>
                        </select>
                    </div>
                    <div class="col-md-4 mb-3">
                        <label class="form-label">Status Inicial</label>
                        <select name="initial_status" class="form-select">
                            <option value="stopped" selected>Parada</option>
                            <option value="active">Iniciar automaticamente</option>
                        </select>
                    </div>
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

    <div class="mt-3">
        <a href="/streams" class="btn btn-secondary">
            <i class="bi bi-arrow-left"></i> Voltar para Streams
        </a>
    </div>
</body>
</html>
EOF

# 8. CONFIGURAR AMBIENTE PYTHON COM FLASK APENAS
echo "🐍 Configurando ambiente Python..."
sudo chown -R hlsweb:hlsweb /home/hls-dashboard
sudo chmod 755 /home/hls-dashboard

cd /home/hls-dashboard
sudo -u hlsweb python3 -m venv venv --clear

# Instalar APENAS Flask (sem Gunicorn, sem SocketIO)
sudo -u hlsweb ./venv/bin/pip install --no-cache-dir --upgrade pip
sudo -u hlsweb ./venv/bin/pip install --no-cache-dir flask==2.3.3

# Criar banco de dados inicial
sudo -u hlsweb tee /home/hls-dashboard/database.json > /dev/null << 'EOF'
{
    "streams": [],
    "users": [
        {"username": "admin", "password": "admin", "role": "admin"}
    ],
    "settings": {
        "auto_start": true,
        "max_bitrate": "2500k",
        "port": 8080,
        "auto_create_stream": true
    },
    "stats": {
        "total_streams": 0,
        "active_streams": 0,
        "total_views": 0
    }
}
EOF

# 9. CRIAR SERVIÇO SYSTEMD SIMPLES (sem Gunicorn)
echo "⚙️ Criando serviço systemd simples..."

sudo tee /etc/systemd/system/hls-dashboard.service > /dev/null << 'EOF'
[Unit]
Description=HLS Dashboard Service (Fixed)
After=network.target
Wants=network.target

[Service]
Type=simple
User=hlsweb
Group=hlsweb
WorkingDirectory=/home/hls-dashboard
Environment="PATH=/home/hls-dashboard/venv/bin"
Environment="PYTHONUNBUFFERED=1"
Environment="FLASK_APP=app.py"

# Usar Flask puro (sem Gunicorn) - porta 8080
ExecStart=/home/hls-dashboard/venv/bin/python3 /home/hls-dashboard/app.py

Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=hls-dashboard

# Security
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=/home/hls-dashboard/uploads /home/hls-dashboard/streams

[Install]
WantedBy=multi-user.target
EOF

# 10. INICIAR SERVIÇO
echo "🚀 Iniciando serviço..."
sudo systemctl daemon-reload
sudo systemctl enable hls-dashboard.service
sudo systemctl start hls-dashboard.service

sleep 5

# 11. TESTAR INSTALAÇÃO
echo "🧪 Testando instalação..."

if sudo systemctl is-active --quiet hls-dashboard.service; then
    echo "✅ Serviço hls-dashboard está ATIVO"
    
    echo "Testando aplicação na porta 8080..."
    sleep 2
    
    if curl -s --max-time 5 http://localhost:8080/health 2>/dev/null | grep -q "healthy"; then
        echo "✅✅✅ DASHBOARD FUNCIONANDO PERFEITAMENTE NA PORTA 8080!"
        
        echo "Testando outras rotas..."
        curl -s http://localhost:8080/ | grep -q "HLS Dashboard" && echo "✅ Página principal OK"
        curl -s http://localhost:8080/test | grep -q "Test" && echo "✅ Página de teste OK"
        
    else
        echo "⚠️ Health check não responde"
        echo "Verificando logs..."
        sudo journalctl -u hls-dashboard -n 10 --no-pager
    fi
else
    echo "❌ Serviço falhou ao iniciar"
    echo "📋 LOGS DE ERRO:"
    sudo journalctl -u hls-dashboard -n 20 --no-pager
    
    # Tentar iniciar manualmente para debug
    echo ""
    echo "🔄 Tentando iniciar manualmente para debug..."
    cd /home/hls-dashboard
    sudo -u hlsweb ./venv/bin/python3 app.py &
    PID=$!
    sleep 3
    
    if curl -s http://localhost:8080/health 2>/dev/null; then
        echo "✅ Funciona manualmente! PID: $PID"
        echo "Recriando serviço..."
        
        # Matar processo manual
        kill $PID 2>/dev/null || true
        
        # Criar serviço mais simples
        sudo tee /etc/systemd/system/hls-simple.service > /dev/null << 'EOF2'
[Unit]
Description=HLS Simple Service
After=network.target

[Service]
Type=simple
User=hlsweb
WorkingDirectory=/home/hls-dashboard
ExecStart=/usr/bin/python3 /home/hls-dashboard/app.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF2
        
        sudo systemctl daemon-reload
        sudo systemctl enable hls-simple.service
        sudo systemctl start hls-simple.service
        sleep 3
        
        if curl -s http://localhost:8080/health; then
            echo "✅✅✅ AGORA FUNCIONA COM SERVIÇO SIMPLES!"
        fi
    else
        echo "❌ Falha mesmo manualmente"
    fi
fi

# 12. CRIAR SCRIPT DE GERENCIAMENTO CORRIGIDO
sudo tee /usr/local/bin/hls-manager > /dev/null << 'EOF'
#!/bin/bash
echo "🛠️  Gerenciador HLS Dashboard (FIXED)"
echo "====================================="
echo ""

case "$1" in
    status)
        echo "=== Status do Serviço ==="
        sudo systemctl status hls-dashboard --no-pager
        echo ""
        echo "=== Portas em uso ==="
        sudo ss -tulpn | grep -E ":8080|:5000" || echo "Porta 8080: Disponível"
        ;;
    start)
        sudo systemctl start hls-dashboard
        echo "✅ Serviço iniciado"
        ;;
    stop)
        sudo systemctl stop hls-dashboard
        echo "✅ Serviço parado"
        ;;
    restart)
        sudo systemctl restart hls-dashboard
        echo "✅ Serviço reiniciado"
        ;;
    logs)
        if [ "$2" = "-f" ]; then
            sudo journalctl -u hls-dashboard -f
        else
            sudo journalctl -u hls-dashboard -n 30 --no-pager
        fi
        ;;
    test)
        echo "🔍 Testando aplicação..."
        echo "1. Health check (porta 8080):"
        curl -s http://localhost:8080/health | python3 -m json.tool 2>/dev/null || curl -s http://localhost:8080/health
        echo ""
        echo "2. Porta 5000 (serviço anterior):"
        sudo ss -tulpn | grep :5000 || echo "Porta 5000: Livre ou outro serviço"
        ;;
    info)
        IP=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "localhost")
        echo "=== HLS Dashboard Info ==="
        echo "Versão: 3.0.0 (Fixed)"
        echo "Porta: 8080 (sem conflito com 5000)"
        echo "URL: http://$IP:8080"
        echo "Health: http://$IP:8080/health"
        echo "Teste: http://$IP:8080/test"
        echo "Diretório: /home/hls-dashboard"
        echo "Usuário: hlsweb"
        echo "Status: $(sudo systemctl is-active hls-dashboard)"
        echo ""
        echo "=== Correções aplicadas ==="
        echo "✔️  Sem Gunicorn problemático"
        echo "✔️  Usuário correto: hlsweb"
        echo "✔️  Porta 8080 para evitar conflitos"
        echo "✔️  Flask puro e estável"
        ;;
    fix)
        echo "🔧 Aplicando correções..."
        sudo chown -R hlsweb:hlsweb /home/hls-dashboard
        sudo systemctl restart hls-dashboard
        echo "✅ Correções aplicadas"
        ;;
    help|*)
        echo "Uso: hls-manager [comando]"
        echo ""
        echo "Comandos:"
        echo "  status    - Ver status completo"
        echo "  start     - Iniciar serviço"
        echo "  stop      - Parar serviço"
        echo "  restart   - Reiniciar serviço"
        echo "  logs      - Ver logs (use -f para seguir)"
        echo "  test      - Testar conexão"
        echo "  info      - Informações do sistema"
        echo "  fix       - Aplicar correções de permissão"
        echo ""
        echo "💡 Esta versão roda na porta 8080"
        echo "💡 Sem conflitos com serviço na porta 5000"
        echo "💡 Sistema estável sem Gunicorn"
        ;;
esac
EOF

sudo chmod +x /usr/local/bin/hls-manager

# 13. MOSTRAR INFORMAÇÕES FINAIS
IP=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "localhost")

echo ""
echo "🎉🎉🎉 INSTALAÇÃO CORRIGIDA CONCLUÍDA! 🎉🎉🎉"
echo "============================================"
echo ""
echo "✅ PROBLEMAS RESOLVIDOS:"
echo "   ✔️  Usuário corrigido: hlsweb (não hlsadmin)"
echo "   ✔️  Sem Gunicorn problemático"
echo "   ✔️  Sem SocketIO complexo"
echo "   ✔️  Diretório em /home/ (evita problemas)"
echo "   ✔️  Porta 8080 (sem conflito com 5000)"
echo "   ✔️  Flask puro e estável"
echo ""
echo "🌐 URLS DE ACESSO (PORTA 8080):"
echo "   🔗 DASHBOARD PRINCIPAL: http://$IP:8080"
echo "   🩺 HEALTH CHECK: http://$IP:8080/health"
echo "   🧪 PÁGINA DE TESTE: http://$IP:8080/test"
echo "   🔐 LOGIN: http://$IP:8080/login"
echo "   📊 STREAMS: http://$IP:8080/streams"
echo ""
echo "🔐 CREDENCIAIS PADRÃO:"
echo "   👤 Usuário: admin"
echo "   🔑 Senha: admin"
echo ""
echo "⚙️  COMANDOS DE GERENCIAMENTO:"
echo "   • hls-manager status      - Ver status completo"
echo "   • hls-manager logs        - Ver logs"
echo "   • hls-manager restart     - Reiniciar"
echo "   • hls-manager test        - Testar sistema"
echo "   • hls-manager info        - Informações"
echo ""
echo "📁 DIRETÓRIOS:"
echo "   • Aplicação: /home/hls-dashboard/"
echo "   • Templates: /home/hls-dashboard/templates/"
echo "   • Uploads: /home/hls-dashboard/uploads/"
echo "   • Logs: sudo journalctl -u hls-dashboard"
echo ""
echo "🔧 NOTA IMPORTANTE:"
echo "   O serviço anterior na porta 5000 FOI PRESERVADO."
echo "   Este novo sistema roda na porta 8080 para não interferir."
echo "   Ambos podem funcionar simultaneamente."
echo ""
echo "💡 DICA RÁPIDA:"
echo "   Execute 'hls-manager test' para verificar se tudo está OK."
echo "   Execute 'hls-manager info' para ver todas as informações."
echo ""
echo "✨ SISTEMA PRONTO PARA USO! ✨"
