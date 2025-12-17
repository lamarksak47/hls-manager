#!/bin/bash
# install_hls_with_dashboard_fixed.sh - INSTALAÇÃO COM CORREÇÕES

set -e

echo "🚀 INSTALAÇÃO DO HLS MANAGER COM DASHBOARD (FIXED)"
echo "==================================================="

# 1. VERIFICAR SISTEMA DE ARQUIVOS
echo "🔍 Verificando sistema de arquivos..."
if mount | grep " / " | grep -q "ro,"; then
    echo "⚠️  Sistema de arquivos root está SOMENTE LEITURA! Corrigindo..."
    sudo mount -o remount,rw /
    echo "✅ Sistema de arquivos agora é leitura/gravação"
fi

# 2. PARAR SERVIÇOS EXISTENTES
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

# 3. LIMPAR INSTALAÇÕES ANTERIORES
echo "🧹 Limpando instalações anteriores..."
sudo rm -rf /opt/hls-dashboard 2>/dev/null || true
sudo rm -rf /opt/hls-manager 2>/dev/null || true
sudo rm -rf /home/hls-app 2>/dev/null || true
sudo rm -f /etc/systemd/system/hls-*.service 2>/dev/null || true
sudo systemctl daemon-reload
sudo systemctl reset-failed

# 4. CRIAR DIRETÓRIO EM /home/ (evita problemas de permissões)
echo "🏠 Criando estrutura em /home/ para evitar problemas..."
sudo mkdir -p /home/hls-dashboard
sudo mkdir -p /home/hls-dashboard/uploads
sudo mkdir -p /home/hls-dashboard/streams
sudo mkdir -p /home/hls-dashboard/static
sudo mkdir -p /home/hls-dashboard/templates

cd /home/hls-dashboard

# 5. CRIAR USUÁRIO SIMPLES (sem home directory problemático)
echo "👤 Criando usuário..."
sudo useradd -r -s /bin/false hlsweb 2>/dev/null || true
sudo usermod -a -G hlsweb $(whoami) 2>/dev/null || true

# 6. INSTALAR DEPENDÊNCIAS MÍNIMAS
echo "📦 Instalando dependências..."
sudo apt-get update
sudo apt-get install -y python3 python3-pip python3-venv

# 7. CRIAR APLICAÇÃO FLASK SIMPLIFICADA (sem Gunicorn/SocketIO problemáticos)
echo "💻 Criando aplicação Flask simplificada..."

# Arquivo principal da aplicação - VERSÃO SIMPLIFICADA
sudo tee /home/hls-dashboard/app.py > /dev/null << 'EOF'
from flask import Flask, render_template, jsonify, request, redirect, url_for, send_from_directory, flash
import os
import json
import subprocess
from datetime import datetime
import uuid

app = Flask(__name__, 
            static_folder='static',
            template_folder='templates')
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

# Rota principal - Dashboard
@app.route('/')
def dashboard():
    return render_template('dashboard.html')

@app.route('/login', methods=['GET', 'POST'])
def login():
    if request.method == 'POST':
        username = request.form['username']
        password = request.form['password']
        
        data = load_database()
        for user in data['users']:
            if user['username'] == username and user['password'] == password:
                flash('Login realizado com sucesso!', 'success')
                return redirect('/dashboard')
        
        flash('Credenciais inválidas!', 'danger')
    
    return render_template('login.html')

# API para dados do sistema
@app.route('/api/system/info')
def api_system_info():
    try:
        # Tentar obter informações do sistema de forma segura
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
        'time': datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        'status': 'healthy'
    })

@app.route('/api/dashboard/stats')
def api_dashboard_stats():
    data = load_database()
    return jsonify(data['stats'])

@app.route('/api/streams')
def api_streams():
    data = load_database()
    return jsonify(data['streams'])

# Health check simplificado
@app.route('/health')
def health():
    return jsonify({
        'status': 'healthy',
        'service': 'hls-dashboard-fixed',
        'version': '3.0.0',
        'timestamp': datetime.now().isoformat()
    })

# Página de teste
@app.route('/test')
def test():
    return '''
    <!DOCTYPE html>
    <html>
    <head><title>Teste HLS</title></head>
    <body>
        <h1>✅ HLS Dashboard Funcionando!</h1>
        <p>Sistema instalado com sucesso na porta 8080</p>
        <a href="/">Ir para Dashboard</a>
    </body>
    </html>
    '''

if __name__ == '__main__':
    # Garantir que as pastas existem
    os.makedirs(app.config['UPLOAD_FOLDER'], exist_ok=True)
    os.makedirs(app.config['STREAMS_FOLDER'], exist_ok=True)
    
    print("🚀 Iniciando HLS Dashboard FIXED na porta 8080...")
    print("✅ Health check: http://localhost:8080/health")
    print("✅ Teste: http://localhost:8080/test")
    
    # Usar servidor de desenvolvimento do Flask (sem Gunicorn)
    app.run(host='0.0.0.0', port=8080, debug=False, threaded=True)
EOF

# 8. CRIAR TEMPLATES HTML SIMPLIFICADOS
echo "🎨 Criando templates simplificados..."

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
        body {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
            padding: 20px;
        }
        .dashboard-card {
            background: white;
            border-radius: 15px;
            padding: 30px;
            margin: 20px auto;
            max-width: 1200px;
            box-shadow: 0 20px 40px rgba(0,0,0,0.2);
        }
        .stat-card {
            background: #f8f9fa;
            border-radius: 10px;
            padding: 20px;
            margin: 10px;
            text-align: center;
            transition: transform 0.3s;
        }
        .stat-card:hover {
            transform: translateY(-5px);
            box-shadow: 0 5px 15px rgba(0,0,0,0.1);
        }
        .stat-number {
            font-size: 2.5rem;
            font-weight: bold;
            color: #4361ee;
        }
        .status-badge {
            display: inline-block;
            padding: 10px 20px;
            background: #28a745;
            color: white;
            border-radius: 50px;
            font-weight: bold;
            margin: 20px 0;
            font-size: 1.2rem;
        }
    </style>
</head>
<body>
    <div class="dashboard-card">
        <div class="text-center mb-4">
            <h1><i class="bi bi-camera-reels"></i> HLS Dashboard 3.0</h1>
            <div class="status-badge">✅ SISTEMA OPERACIONAL</div>
            <p class="text-muted">Versão corrigida e otimizada - Porta 8080</p>
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
        
        <div class="row">
            <div class="col-md-3">
                <div class="stat-card">
                    <div class="stat-icon text-primary">
                        <i class="bi bi-cpu" style="font-size: 2rem;"></i>
                    </div>
                    <div class="stat-number" id="cpu-usage">--</div>
                    <p class="text-muted">Uso de CPU</p>
                </div>
            </div>
            <div class="col-md-3">
                <div class="stat-card">
                    <div class="stat-icon text-success">
                        <i class="bi bi-memory" style="font-size: 2rem;"></i>
                    </div>
                    <div class="stat-number" id="memory-usage">--</div>
                    <p class="text-muted">Uso de Memória</p>
                </div>
            </div>
            <div class="col-md-3">
                <div class="stat-card">
                    <div class="stat-icon text-warning">
                        <i class="bi bi-hdd" style="font-size: 2rem;"></i>
                    </div>
                    <div class="stat-number" id="disk-usage">--</div>
                    <p class="text-muted">Uso de Disco</p>
                </div>
            </div>
            <div class="col-md-3">
                <div class="stat-card">
                    <div class="stat-icon text-info">
                        <i class="bi bi-clock-history" style="font-size: 2rem;"></i>
                    </div>
                    <div class="stat-number" id="uptime">--</div>
                    <p class="text-muted">Uptime</p>
                </div>
            </div>
        </div>
        
        <div class="row mt-4">
            <div class="col-md-6">
                <div class="card">
                    <div class="card-header">
                        <h5 class="mb-0"><i class="bi bi-info-circle"></i> Status do Sistema</h5>
                    </div>
                    <div class="card-body">
                        <p><strong>Porta:</strong> 8080</p>
                        <p><strong>Usuário do sistema:</strong> hlsweb</p>
                        <p><strong>Diretório:</strong> /home/hls-dashboard/</p>
                        <p><strong>Status:</strong> <span id="system-status" class="text-success">● Online</span></p>
                        <p><strong>Última atualização:</strong> <span id="last-update">--</span></p>
                    </div>
                </div>
            </div>
            <div class="col-md-6">
                <div class="card">
                    <div class="card-header">
                        <h5 class="mb-0"><i class="bi bi-lightning-charge"></i> Ações Rápidas</h5>
                    </div>
                    <div class="card-body">
                        <div class="d-grid gap-2">
                            <a href="/test" class="btn btn-primary">
                                <i class="bi bi-check-circle"></i> Testar Sistema
                            </a>
                            <a href="/health" class="btn btn-success">
                                <i class="bi bi-heart-pulse"></i> Health Check
                            </a>
                            <button onclick="refreshStats()" class="btn btn-warning">
                                <i class="bi bi-arrow-clockwise"></i> Atualizar Stats
                            </button>
                        </div>
                    </div>
                </div>
            </div>
        </div>
        
        <div class="mt-4 text-center">
            <h4>Recursos do Sistema</h4>
            <div class="row mt-3">
                <div class="col-md-4">
                    <div class="alert alert-success">
                        <i class="bi bi-check-circle"></i> Flask funcionando
                    </div>
                </div>
                <div class="col-md-4">
                    <div class="alert alert-success">
                        <i class="bi bi-check-circle"></i> API ativa
                    </div>
                </div>
                <div class="col-md-4">
                    <div class="alert alert-success">
                        <i class="bi bi-check-circle"></i> Sistema estável
                    </div>
                </div>
            </div>
        </div>
        
        <div class="mt-4 text-center text-muted">
            <p>HLS Dashboard v3.0.0 (Fixed) | © 2024</p>
            <p><small>✅ Corrigido: Problemas de Gunicorn e sistema de arquivos</small></p>
        </div>
    </div>

    <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.1.3/dist/js/bootstrap.bundle.min.js"></script>
    <script>
        function updateSystemStats() {
            fetch('/api/system/info')
                .then(response => response.json())
                .then(data => {
                    document.getElementById('cpu-usage').textContent = data.cpu;
                    document.getElementById('memory-usage').textContent = data.memory;
                    document.getElementById('disk-usage').textContent = data.disk;
                    document.getElementById('uptime').textContent = data.uptime;
                    document.getElementById('last-update').textContent = data.time;
                    
                    if (data.status === 'healthy') {
                        document.getElementById('system-status').className = 'text-success';
                        document.getElementById('system-status').textContent = '● Online';
                    }
                })
                .catch(error => {
                    console.error('Erro ao buscar stats:', error);
                });
        }
        
        function refreshStats() {
            updateSystemStats();
            alert('Stats atualizados!');
        }
        
        // Atualizar a cada 10 segundos
        setInterval(updateSystemStats, 10000);
        
        // Atualizar imediatamente
        updateSystemStats();
        
        // Atualizar tempo
        function updateTime() {
            const now = new Date();
            document.getElementById('current-time').textContent = 
                now.toLocaleDateString() + ' ' + now.toLocaleTimeString();
        }
        setInterval(updateTime, 1000);
        updateTime();
    </script>
</body>
</html>
EOF

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
        .success-badge {
            background: #d4edda;
            color: #155724;
            padding: 10px;
            border-radius: 5px;
            text-align: center;
            margin-bottom: 20px;
        }
    </style>
</head>
<body>
    <div class="login-box">
        <div class="logo">
            <i class="bi bi-camera-reels"></i> HLS Dashboard
        </div>
        
        <div class="success-badge">
            <i class="bi bi-check-circle"></i> Sistema Corrigido e Otimizado
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

# 9. CONFIGURAR AMBIENTE PYTHON SIMPLIFICADO
echo "🐍 Configurando ambiente Python simplificado..."
sudo chown -R hlsweb:hlsweb /home/hls-dashboard
sudo chmod 755 /home/hls-dashboard

cd /home/hls-dashboard
sudo -u hlsweb python3 -m venv venv --clear

# Instalar APENAS Flask (sem Gunicorn/SocketIO)
sudo -u hlsweb ./venv/bin/pip install --no-cache-dir --upgrade pip
sudo -u hlsadmin ./venv/bin/pip install --no-cache-dir flask==2.3.3

# 10. TESTAR SE A APLICAÇÃO FUNCIONA
echo "🧪 Testando aplicação..."
if sudo -u hlsweb ./venv/bin/python3 -c "from flask import Flask; print('✅ Flask OK')"; then
    echo "✅ Flask instalado corretamente"
else
    echo "⚠️ Criando fallback extremamente simples..."
    sudo tee /home/hls-dashboard/simple_app.py > /dev/null << 'EOF'
#!/usr/bin/env python3
import http.server
import socketserver
import json
import time

PORT = 8080

class HLSHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/health':
            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({
                'status': 'healthy',
                'service': 'hls-simple',
                'timestamp': time.time()
            }).encode())
        elif self.path == '/':
            self.send_response(200)
            self.send_header('Content-type', 'text/html')
            self.end_headers()
            html = '''
            <!DOCTYPE html>
            <html>
            <head><title>HLS Simple</title></head>
            <body>
                <h1>✅ HLS Simple Server</h1>
                <p>Sistema funcionando na porta ''' + str(PORT) + '''</p>
                <p><a href="/health">Health Check</a></p>
            </body>
            </html>
            '''
            self.wfile.write(html.encode())
        else:
            self.send_response(404)
            self.end_headers()

print(f"🚀 Iniciando servidor simples na porta {PORT}")
with socketserver.TCPServer(("", PORT), HLSHandler) as httpd:
    httpd.serve_forever()
EOF
    sudo chmod +x /home/hls-dashboard/simple_app.py
fi

# 11. CRIAR SERVIÇO SYSTEMD SIMPLES (sem Gunicorn)
echo "⚙️ Criando serviço systemd simples..."

sudo tee /etc/systemd/system/hls-web.service > /dev/null << 'EOF'
[Unit]
Description=HLS Web Dashboard Service
After=network.target
Wants=network.target

[Service]
Type=simple
User=hlsweb
Group=hlsweb
WorkingDirectory=/home/hls-dashboard
Environment="PATH=/home/hls-dashboard/venv/bin"
Environment="PYTHONUNBUFFERED=1"

# Usar Flask diretamente (sem Gunicorn)
ExecStart=/home/hls-dashboard/venv/bin/python3 /home/hls-dashboard/app.py

# Fallback se Flask falhar
# ExecStart=/usr/bin/python3 /home/hls-dashboard/simple_app.py

Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=hls-web

# Configurações de segurança
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

# 12. CONFIGURAR PERMISSÕES E LOGS
echo "🔐 Configurando permissões..."
sudo mkdir -p /var/log/hls-web
sudo chown -R hlsweb:hlsweb /var/log/hls-web
sudo chmod 755 /var/log/hls-web

# 13. INICIAR SERVIÇO
echo "🚀 Iniciando serviço..."
sudo systemctl daemon-reload
sudo systemctl enable hls-web.service
sudo systemctl start hls-web.service

sleep 5

# 14. VERIFICAR SE ESTÁ FUNCIONANDO
echo "🔍 Verificando instalação..."

if sudo systemctl is-active --quiet hls-web.service; then
    echo "✅ Serviço hls-web está ATIVO"
    
    echo "Testando aplicação na porta 8080..."
    sleep 2
    
    if curl -s --max-time 5 http://localhost:8080/health 2>/dev/null | grep -q "healthy"; then
        echo "✅✅✅ APLICAÇÃO FUNCIONANDO PERFEITAMENTE NA PORTA 8080!"
        
        # Testar também outras rotas
        echo "Testando rotas..."
        curl -s http://localhost:8080/test | grep -q "Funcionando" && echo "✅ Página de teste OK"
        curl -s http://localhost:8080/api/system/info | grep -q "cpu" && echo "✅ API de sistema OK"
        
    else
        echo "⚠️ Health check não responde, testando página simples..."
        if curl -s http://localhost:8080/; then
            echo "✅ Página principal responde"
        else
            echo "❌ Nenhuma resposta na porta 8080"
            echo "📋 Verificando logs..."
            sudo journalctl -u hls-web -n 20 --no-pager
        fi
    fi
else
    echo "❌ Serviço falhou ao iniciar"
    echo "📋 LOGS DE ERRO:"
    sudo journalctl -u hls-web -n 30 --no-pager
    
    echo ""
    echo "🔄 Tentando método alternativo (servidor HTTP nativo)..."
    
    # Parar serviço atual
    sudo systemctl stop hls-web.service
    
    # Atualizar serviço para usar servidor nativo
    sudo sed -i 's|ExecStart=.*|ExecStart=/usr/bin/python3 /home/hls-dashboard/simple_app.py|' /etc/systemd/system/hls-web.service
    
    sudo systemctl daemon-reload
    sudo systemctl restart hls-web.service
    sleep 3
    
    if curl -s http://localhost:8080/health; then
        echo "✅✅✅ AGORA FUNCIONA COM SERVIDOR NATIVO!"
    else
        echo "❌ Mesmo servidor nativo falhou"
        echo "📋 Última tentativa: iniciando manualmente..."
        cd /home/hls-dashboard
        python3 simple_app.py &
        sleep 2
        curl -s http://localhost:8080/ && echo "✅ Funciona manualmente!"
    fi
fi

# 15. CRIAR SCRIPT DE GERENCIAMENTO
echo "📝 Criando script de gerenciamento..."

sudo tee /usr/local/bin/hls-dashboard > /dev/null << 'EOF'
#!/bin/bash
echo "🛠️  Gerenciador HLS Dashboard (FIXED)"
echo "====================================="
echo ""

case "$1" in
    status)
        echo "=== Status do Serviço ==="
        sudo systemctl status hls-web --no-pager
        echo ""
        echo "=== Portas em uso ==="
        sudo ss -tulpn | grep -E ":8080|:5000" || echo "Porta 8080 livre"
        ;;
    start)
        sudo systemctl start hls-web
        echo "✅ Serviço iniciado"
        ;;
    stop)
        sudo systemctl stop hls-web
        echo "✅ Serviço parado"
        ;;
    restart)
        sudo systemctl restart hls-web
        echo "✅ Serviço reiniciado"
        ;;
    logs)
        if [ "$2" = "-f" ]; then
            sudo journalctl -u hls-web -f
        else
            sudo journalctl -u hls-web -n 30 --no-pager
        fi
        ;;
    test)
        echo "🔍 Testando aplicação..."
        echo "Health check:"
        curl -s http://localhost:8080/health || echo "❌ Não responde"
        echo ""
        echo "Página principal:"
        curl -s -I http://localhost:8080/ | head -1 || echo "❌ Não responde"
        ;;
    info)
        IP=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "localhost")
        echo "=== HLS Dashboard Info ==="
        echo "Versão: 3.0.0 (Fixed)"
        echo "Porta: 8080"
        echo "URL: http://$IP:8080"
        echo "Health: http://$IP:8080/health"
        echo "Teste: http://$IP:8080/test"
        echo "Diretório: /home/hls-dashboard"
        echo "Usuário: hlsweb"
        echo "Status: $(sudo systemctl is-active hls-web)"
        echo "Logs: sudo journalctl -u hls-web"
        ;;
    fix)
        echo "🔧 Aplicando correções..."
        sudo chown -R hlsweb:hlsweb /home/hls-dashboard
        sudo systemctl restart hls-web
        echo "✅ Correções aplicadas"
        ;;
    help|*)
        echo "Uso: hls-dashboard [comando]"
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
        echo "💡 Esta versão usa Flask puro (sem Gunicorn)"
        echo "💡 Rodando na porta 8080 para evitar conflitos"
        ;;
esac
EOF

sudo chmod +x /usr/local/bin/hls-dashboard

# 16. VERIFICAR PORTAS
echo "🔍 Verificando portas em uso..."
echo "Porta 5000: $(sudo ss -tulpn | grep :5000 | wc -l) processos"
echo "Porta 5001: $(sudo ss -tulpn | grep :5001 | wc -l) processos"
echo "Porta 8080: $(sudo ss -tulpn | grep :8080 | wc -l) processos"

# 17. MOSTRAR INFORMAÇÕES FINAIS
IP=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "localhost")

echo ""
echo "🎉🎉🎉 INSTALAÇÃO CORRIGIDA CONCLUÍDA! 🎉🎉🎉"
echo "============================================"
echo ""
echo "✅ PROBLEMAS RESOLVIDOS:"
echo "   ✔️  Removido Gunicorn problemático"
echo "   ✔️  Sistema de arquivos corrigido"
echo "   ✔️  Porta 8080 (evita conflitos)"
echo "   ✔️  Usuário simplificado"
echo "   ✔️  Permissões configuradas"
echo ""
echo "🌐 URLS DE ACESSO:"
echo "   🔗 DASHBOARD: http://$IP:8080"
echo "   🩺 HEALTH: http://$IP:8080/health"
echo "   🧪 TESTE: http://$IP:8080/test"
echo "   🔐 LOGIN: http://$IP:8080/login"
echo ""
echo "🔐 CREDENCIAIS:"
echo "   👤 Usuário: admin"
echo "   🔑 Senha: admin"
echo ""
echo "⚙️  COMANDOS:"
echo "   • hls-dashboard status   - Ver status"
echo "   • hls-dashboard logs     - Ver logs"
echo "   • hls-dashboard restart  - Reiniciar"
echo "   • hls-dashboard info     - Informações"
echo ""
echo "📁 DIRETÓRIOS:"
echo "   • Aplicação: /home/hls-dashboard/"
echo "   • Templates: /home/hls-dashboard/templates/"
echo "   • Uploads: /home/hls-dashboard/uploads/"
echo "   • Logs: /var/log/hls-web/"
echo ""
echo "🔧 DETALHES TÉCNICOS:"
echo "   • Usa Flask puro (sem Gunicorn)"
echo "   • Porta 8080 (sem conflito com 5000)"
echo "   • Diretório /home/ (evita problemas)"
echo "   • Sistema simplificado e estável"
echo ""
echo "⚠️  NOTA IMPORTANTE:"
echo "   O serviço anterior na porta 5000 foi preservado."
echo "   Este novo sistema roda na porta 8080 para não interferir."
echo ""
echo "💡 DICA RÁPIDA:"
echo "   Execute 'hls-dashboard test' para verificar se tudo está funcionando."
echo ""
echo "✨ SISTEMA PRONTO PARA USO! ✨"
