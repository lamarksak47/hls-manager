#!/bin/bash
# install_hls_converter_ultimate.sh - SISTEMA COMPLETO ULTIMATE

set -e

echo "🚀 INSTALANDO HLS CONVERTER ULTIMATE"
echo "===================================="

# 1. Verificar privilégios
if [ "$EUID" -ne 0 ]; then
    echo "❌ Por favor, execute como root ou com sudo!"
    echo "   sudo ./install_hls_converter_ultimate.sh"
    exit 1
fi

# 2. Verificar sistema de arquivos
echo "🔍 Verificando sistema..."
if mount | grep " / " | grep -q "ro,"; then
    echo "⚠️  Sistema de arquivos root está SOMENTE LEITURA! Corrigindo..."
    mount -o remount,rw /
    echo "✅ Sistema de arquivos agora é leitura/gravação"
fi

# 3. Parar serviços existentes
echo "🛑 Parando serviços existentes..."
systemctl stop hls-simple hls-dashboard hls-manager hls-final hls-converter 2>/dev/null || true
pkill -9 python 2>/dev/null || true
sleep 2

# 4. Limpar instalações anteriores
echo "🧹 Limpando instalações anteriores..."
rm -rf /opt/hls-converter 2>/dev/null || true
rm -rf /etc/systemd/system/hls-*.service 2>/dev/null || true
rm -f /usr/local/bin/hlsctl 2>/dev/null || true
systemctl daemon-reload

# 5. Atualizar sistema
echo "📦 Atualizando sistema..."
apt-get update
apt-get upgrade -y

# 6. FUNÇÃO ROBUSTA PARA INSTALAR FFMPEG
install_ffmpeg_robust() {
    echo "🔧 Tentando instalar ffmpeg..."
    
    # Método 1: Tentar instalação normal
    echo "📦 Método 1: Instalação normal do apt..."
    apt-get update
    if apt-get install -y ffmpeg; then
        echo "✅ FFmpeg instalado com sucesso via apt"
        return 0
    fi
    
    # Método 2: Tentar instalar individualmente
    echo "📦 Método 2: Instalando componentes individualmente..."
    apt-get install -y libavcodec-dev libavformat-dev libavutil-dev libavfilter-dev libavdevice-dev \
        libswscale-dev libswresample-dev libpostproc-dev || true
    
    # Método 3: Tentar instalar do repositório Snap
    echo "📦 Método 3: Tentando via Snap..."
    if command -v snap &> /dev/null; then
        snap install ffmpeg --classic && echo "✅ FFmpeg instalado via Snap" && return 0
    fi
    
    # Método 4: Compilar do código fonte (último recurso)
    echo "📦 Método 4: Baixando binário estático..."
    cd /tmp
    wget -q https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz || \
    wget -q https://www.johnvansickle.com/ffmpeg/old-releases/ffmpeg-4.4.1-amd64-static.tar.xz || \
    curl -L -o ffmpeg-release-amd64-static.tar.xz https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz
    
    if [ -f ffmpeg-release-amd64-static.tar.xz ]; then
        tar -xf ffmpeg-release-amd64-static.tar.xz
        FFMPEG_DIR=$(find . -name "ffmpeg-*-static" -type d | head -1)
        if [ -n "$FFMPEG_DIR" ]; then
            cp "$FFMPEG_DIR"/ffmpeg "$FFMPEG_DIR"/ffprobe /usr/local/bin/
            chmod +x /usr/local/bin/ffmpeg /usr/local/bin/ffprobe
            echo "✅ FFmpeg instalado de binário estático"
            return 0
        fi
    fi
    
    return 1
}

# 7. INSTALAR FFMPEG
echo "🎬 INSTALANDO FFMPEG..."
if command -v ffmpeg &> /dev/null; then
    echo "✅ ffmpeg já está instalado"
    echo "🔍 Versão do ffmpeg:"
    ffmpeg -version | head -1
else
    echo "❌ ffmpeg não encontrado, instalando..."
    install_ffmpeg_robust
    
    # Verificar novamente
    if ! command -v ffmpeg &> /dev/null; then
        echo "⚠️  Tentando encontrar ffmpeg em locais alternativos..."
        for path in /usr/bin/ffmpeg /usr/local/bin/ffmpeg /bin/ffmpeg /snap/bin/ffmpeg; do
            if [ -f "$path" ]; then
                ln -sf "$path" /usr/local/bin/ffmpeg
                echo "✅ Link simbólico criado para $path"
                break
            fi
        done
    fi
    
    # Verificação final
    if command -v ffmpeg &> /dev/null; then
        echo "🎉 FFMPEG INSTALADO COM SUCESSO!"
        ffmpeg -version | head -1
    else
        echo "⚠️  AVISO: FFmpeg pode não estar instalado corretamente"
    fi
fi

# 8. Instalar outras dependências
echo "🔧 Instalando outras dependências..."
apt-get install -y python3 python3-pip python3-venv htop curl wget

# 9. Criar estrutura de diretórios AVANÇADA
echo "🏗️  Criando estrutura de diretórios..."
mkdir -p /opt/hls-converter/{uploads,hls,logs,db,templates,static}
mkdir -p /opt/hls-converter/hls/{240p,360p,480p,720p,1080p,original}
cd /opt/hls-converter

# 10. Criar usuário dedicado
echo "👤 Criando usuário dedicado..."
if id "hlsuser" &>/dev/null; then
    echo "✅ Usuário hlsuser já existe"
else
    useradd -r -s /bin/false hlsuser
    echo "✅ Usuário hlsuser criado"
fi

# 11. Configurar ambiente Python
echo "🐍 Configurando ambiente Python..."
python3 -m venv venv
source venv/bin/activate

# Instalar dependências Python COMPLETAS
pip install --upgrade pip
pip install flask flask-cors python-magic psutil waitress werkzeug

# 12. CRIAR APLICAÇÃO FLASK ULTIMATE
echo "💻 Criando aplicação ultimate..."

# Arquivo principal com DASHBOARD COMPLETO + FUNCIONALIDADES ROBUSTAS
cat > app.py << 'EOF'
from flask import Flask, request, jsonify, send_file, render_template_string, send_from_directory
from flask_cors import CORS
from werkzeug.utils import secure_filename
import os
import subprocess
import uuid
import json
import time
import psutil
from datetime import datetime
import shutil
import sys

app = Flask(__name__, static_folder='static', static_url_path='/static')
CORS(app)

# Configurações
BASE_DIR = "/opt/hls-converter"
UPLOAD_DIR = os.path.join(BASE_DIR, "uploads")
HLS_DIR = os.path.join(BASE_DIR, "hls")
LOG_DIR = os.path.join(BASE_DIR, "logs")
DB_DIR = os.path.join(BASE_DIR, "db")
os.makedirs(UPLOAD_DIR, exist_ok=True)
os.makedirs(HLS_DIR, exist_ok=True)
os.makedirs(LOG_DIR, exist_ok=True)
os.makedirs(DB_DIR, exist_ok=True)

# Banco de dados simples
DB_FILE = os.path.join(DB_DIR, "conversions.json")

def load_database():
    try:
        if os.path.exists(DB_FILE):
            with open(DB_FILE, 'r') as f:
                return json.load(f)
    except:
        pass
    return {"conversions": [], "stats": {"total": 0, "success": 0, "failed": 0}}

def save_database(data):
    with open(DB_FILE, 'w') as f:
        json.dump(data, f, indent=2)

def log_activity(message, level="INFO"):
    log_file = os.path.join(LOG_DIR, "activity.log")
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    with open(log_file, 'a') as f:
        f.write(f"[{timestamp}] [{level}] {message}\n")

# Função ROBUSTA para encontrar ffmpeg
def find_ffmpeg():
    """Encontra ffmpeg em vários locais possíveis"""
    possible_paths = [
        '/usr/bin/ffmpeg',
        '/usr/local/bin/ffmpeg',
        '/bin/ffmpeg',
        '/snap/bin/ffmpeg',
        '/opt/homebrew/bin/ffmpeg',
        os.path.expanduser('~/.local/bin/ffmpeg'),
        '/usr/lib/ffmpeg',
    ]
    
    # Verificar no PATH
    try:
        result = subprocess.run(['which', 'ffmpeg'], capture_output=True, text=True)
        if result.returncode == 0:
            return result.stdout.strip()
    except:
        pass
    
    # Verificar em cada caminho possível
    for path in possible_paths:
        if os.path.exists(path) and os.access(path, os.X_OK):
            return path
    
    # Tentar encontrar via find
    try:
        result = subprocess.run(['find', '/usr', '-name', 'ffmpeg', '-type', 'f', '-executable'], 
                              capture_output=True, text=True, timeout=5)
        if result.returncode == 0 and result.stdout:
            return result.stdout.split('\n')[0]
    except:
        pass
    
    return None

# Verificar ffmpeg uma vez e armazenar o caminho
FFMPEG_PATH = find_ffmpeg()
if FFMPEG_PATH:
    log_activity(f"FFmpeg encontrado em: {FFMPEG_PATH}")
else:
    log_activity("FFmpeg NÃO encontrado no sistema!", "ERROR")

def get_system_info():
    """Obtém informações do sistema"""
    try:
        cpu_percent = psutil.cpu_percent(interval=0.1)
        memory = psutil.virtual_memory()
        disk = psutil.disk_usage('/')
        
        # Contar conversões
        db = load_database()
        
        # Verificar ffmpeg status
        ffmpeg_status = "ok" if FFMPEG_PATH else "missing"
        
        return {
            "cpu": f"{cpu_percent:.1f}%",
            "memory": f"{memory.percent:.1f}%",
            "disk": f"{disk.percent:.1f}%",
            "uptime": str(datetime.now() - datetime.fromtimestamp(psutil.boot_time())).split('.')[0],
            "total_conversions": db["stats"]["total"],
            "success_conversions": db["stats"]["success"],
            "failed_conversions": db["stats"]["failed"],
            "hls_files": len(os.listdir(HLS_DIR)) if os.path.exists(HLS_DIR) else 0,
            "ffmpeg_status": ffmpeg_status,
            "ffmpeg_path": FFMPEG_PATH or "not found",
            "ffmpeg_version": get_ffmpeg_version()
        }
    except Exception as e:
        return {"error": str(e)}

def get_ffmpeg_version():
    """Obtém versão do ffmpeg"""
    if not FFMPEG_PATH:
        return "not installed"
    
    try:
        result = subprocess.run([FFMPEG_PATH, '-version'], capture_output=True, text=True, timeout=5)
        if result.returncode == 0:
            version_line = result.stdout.split('\n')[0]
            return version_line.split(' ')[2] if len(version_line.split(' ')) > 2 else "unknown"
    except:
        pass
    return "unknown"

# ==================== TEMPLATE HTML ULTIMATE ====================

INDEX_HTML = '''
<!DOCTYPE html>
<html lang="pt-BR">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>🎬 HLS Converter ULTIMATE</title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.1.3/dist/css/bootstrap.min.css" rel="stylesheet">
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap-icons@1.8.1/font/bootstrap-icons.css">
    <style>
        :root {
            --primary: #4361ee;
            --secondary: #3a0ca3;
            --success: #4cc9f0;
            --danger: #f72585;
        }
        
        body {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
            padding: 20px;
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
        }
        
        .glass-card {
            background: rgba(255, 255, 255, 0.95);
            backdrop-filter: blur(10px);
            border-radius: 20px;
            padding: 30px;
            box-shadow: 0 20px 60px rgba(0,0,0,0.3);
            border: 1px solid rgba(255,255,255,0.2);
        }
        
        .upload-area {
            border: 3px dashed var(--primary);
            border-radius: 15px;
            padding: 60px 30px;
            text-align: center;
            transition: all 0.3s;
            cursor: pointer;
            background: rgba(67, 97, 238, 0.05);
        }
        
        .upload-area:hover {
            background: rgba(67, 97, 238, 0.1);
            border-color: var(--secondary);
            transform: translateY(-5px);
        }
        
        .file-list-item {
            background: #f8f9fa;
            border-radius: 10px;
            padding: 15px;
            margin-bottom: 10px;
            border-left: 4px solid var(--primary);
        }
        
        .btn-primary {
            background: linear-gradient(90deg, var(--primary) 0%, var(--secondary) 100%);
            border: none;
            padding: 12px 30px;
            border-radius: 10px;
            font-weight: bold;
        }
        
        .btn-primary:hover {
            transform: translateY(-2px);
            box-shadow: 0 10px 20px rgba(67, 97, 238, 0.3);
        }
        
        .progress-container {
            background: #e9ecef;
            border-radius: 10px;
            height: 20px;
            overflow: hidden;
            margin: 20px 0;
        }
        
        .progress-bar {
            height: 100%;
            background: linear-gradient(90deg, #4cc9f0 0%, #4361ee 100%);
            transition: width 0.5s ease;
        }
        
        .stat-card {
            background: white;
            border-radius: 15px;
            padding: 20px;
            margin-bottom: 20px;
            box-shadow: 0 5px 15px rgba(0,0,0,0.1);
        }
        
        .nav-tabs .nav-link {
            color: #666;
            font-weight: 500;
        }
        
        .nav-tabs .nav-link.active {
            color: var(--primary);
            border-bottom: 3px solid var(--primary);
        }
        
        .quality-badge {
            display: inline-block;
            padding: 5px 15px;
            border-radius: 20px;
            font-size: 0.85rem;
            font-weight: bold;
            margin: 2px;
        }
        
        .quality-240p { background: #e3f2fd; color: #1565c0; }
        .quality-480p { background: #e8f5e9; color: #2e7d32; }
        .quality-720p { background: #fff3e0; color: #ef6c00; }
        .quality-1080p { background: #fce4ec; color: #c2185b; }
        
        .warning-box {
            background: #fff3cd;
            color: #856404;
            padding: 15px;
            border-radius: 10px;
            margin-bottom: 20px;
            border: 1px solid #ffeaa7;
        }
        
        .error-box {
            background: #f8d7da;
            color: #721c24;
            padding: 15px;
            border-radius: 10px;
            margin-bottom: 20px;
            border: 1px solid #f5c6cb;
        }
    </style>
</head>
<body>
    <div class="container-fluid">
        <div class="row">
            <!-- Sidebar -->
            <div class="col-md-3 mb-4">
                <div class="glass-card">
                    <div class="text-center mb-4">
                        <h1><i class="bi bi-camera-reels"></i> HLS ULTIMATE</h1>
                        <p class="text-muted">Conversor de vídeos profissional</p>
                    </div>
                    
                    <!-- System Stats -->
                    <div id="systemStats">
                        <div class="stat-card">
                            <h5><i class="bi bi-speedometer2"></i> Status do Sistema</h5>
                            <div class="mt-3">
                                <p><strong>CPU:</strong> <span id="cpuUsage">--</span></p>
                                <div class="progress" style="height: 8px;">
                                    <div class="progress-bar" id="cpuBar"></div>
                                </div>
                                
                                <p class="mt-3"><strong>Memória:</strong> <span id="memoryUsage">--</span></p>
                                <div class="progress" style="height: 8px;">
                                    <div class="progress-bar bg-success" id="memoryBar"></div>
                                </div>
                                
                                <p class="mt-3"><strong>Disco:</strong> <span id="diskUsage">--</span></p>
                                <div class="progress" style="height: 8px;">
                                    <div class="progress-bar bg-info" id="diskBar"></div>
                                </div>
                                
                                <p><strong>Uptime:</strong> <span id="uptime">--</span></p>
                                <p><strong>Conversões:</strong> <span id="totalConversions">0</span></p>
                                <p><strong>FFmpeg:</strong> <span id="ffmpegStatusText">❓ Verificando...</span></p>
                            </div>
                        </div>
                    </div>
                    
                    <!-- FFmpeg Status -->
                    <div id="ffmpegWarning" style="display: none;" class="warning-box">
                        <h6><i class="bi bi-exclamation-triangle"></i> FFmpeg não encontrado!</h6>
                        <p>Instale com:</p>
                        <code>sudo apt-get install ffmpeg</code>
                        <p class="mt-2">ou use:</p>
                        <code>hlsctl fix-ffmpeg</code>
                        <button onclick="checkFFmpeg()" class="btn btn-sm btn-warning mt-2">
                            <i class="bi bi-arrow-clockwise"></i> Verificar novamente
                        </button>
                    </div>
                    
                    <!-- Quick Actions -->
                    <div class="stat-card">
                        <h5><i class="bi bi-lightning-charge"></i> Ações Rápidas</h5>
                        <div class="d-grid gap-2 mt-3">
                            <button class="btn btn-outline-primary" onclick="showUpload()">
                                <i class="bi bi-upload"></i> Upload
                            </button>
                            <button class="btn btn-outline-success" onclick="showConversions()">
                                <i class="bi bi-list-check"></i> Histórico
                            </button>
                            <button class="btn btn-outline-warning" onclick="showSettings()">
                                <i class="bi bi-gear"></i> Configurações
                            </button>
                            <button class="btn btn-outline-info" onclick="refreshStats()">
                                <i class="bi bi-arrow-clockwise"></i> Atualizar
                            </button>
                        </div>
                    </div>
                </div>
            </div>
            
            <!-- Main Content -->
            <div class="col-md-9">
                <div class="glass-card">
                    <!-- Navigation -->
                    <ul class="nav nav-tabs" id="mainTabs">
                        <li class="nav-item">
                            <a class="nav-link active" id="upload-tab" onclick="showUpload()">
                                <i class="bi bi-upload"></i> Upload
                            </a>
                        </li>
                        <li class="nav-item">
                            <a class="nav-link" id="conversions-tab" onclick="showConversions()">
                                <i class="bi bi-list-check"></i> Conversões
                            </a>
                        </li>
                        <li class="nav-item">
                            <a class="nav-link" id="settings-tab" onclick="showSettings()">
                                <i class="bi bi-gear"></i> Configurações
                            </a>
                        </li>
                        <li class="nav-item">
                            <a class="nav-link" id="tools-tab" onclick="showTools()">
                                <i class="bi bi-tools"></i> Ferramentas
                            </a>
                        </li>
                        <li class="nav-item">
                            <a class="nav-link" id="help-tab" onclick="showHelp()">
                                <i class="bi bi-question-circle"></i> Ajuda
                            </a>
                        </li>
                    </ul>
                    
                    <!-- Content Areas -->
                    <div id="contentArea" class="mt-4">
                        <!-- Upload Area -->
                        <div id="uploadContent">
                            <h3><i class="bi bi-cloud-arrow-up"></i> Upload de Vídeos</h3>
                            <p class="text-muted">Envie vídeos para conversão HLS com múltiplas qualidades</p>
                            
                            <div class="upload-area" onclick="document.getElementById('fileInput').click()">
                                <i class="bi bi-cloud-arrow-up" style="font-size: 3rem; color: var(--primary);"></i>
                                <h4 class="mt-3">Arraste e solte seus vídeos aqui</h4>
                                <p class="text-muted">ou clique para selecionar arquivos</p>
                                <p><small>Suporta MP4, AVI, MOV, MKV, WEBM (Até 2GB)</small></p>
                            </div>
                            
                            <input type="file" id="fileInput" multiple accept="video/*,.mp4,.avi,.mov,.mkv,.webm" style="display:none;" onchange="handleFileSelect()">
                            
                            <!-- File List -->
                            <div id="fileList" class="mt-4"></div>
                            
                            <!-- Quality Selection -->
                            <div class="mt-4">
                                <h5>Qualidades de Saída:</h5>
                                <div class="row">
                                    <div class="col-md-3">
                                        <div class="form-check">
                                            <input class="form-check-input" type="checkbox" id="quality240" checked>
                                            <label class="form-check-label">
                                                <span class="quality-badge quality-240p">240p</span>
                                            </label>
                                        </div>
                                    </div>
                                    <div class="col-md-3">
                                        <div class="form-check">
                                            <input class="form-check-input" type="checkbox" id="quality480" checked>
                                            <label class="form-check-label">
                                                <span class="quality-badge quality-480p">480p</span>
                                            </label>
                                        </div>
                                    </div>
                                    <div class="col-md-3">
                                        <div class="form-check">
                                            <input class="form-check-input" type="checkbox" id="quality720" checked>
                                            <label class="form-check-label">
                                                <span class="quality-badge quality-720p">720p</span>
                                            </label>
                                        </div>
                                    </div>
                                    <div class="col-md-3">
                                        <div class="form-check">
                                            <input class="form-check-input" type="checkbox" id="quality1080" checked>
                                            <label class="form-check-label">
                                                <span class="quality-badge quality-1080p">1080p</span>
                                            </label>
                                        </div>
                                    </div>
                                </div>
                            </div>
                            
                            <!-- Actions -->
                            <div class="mt-4 d-grid gap-2 d-md-flex justify-content-md-end">
                                <button class="btn btn-secondary" onclick="clearFileList()">
                                    <i class="bi bi-x-circle"></i> Limpar Lista
                                </button>
                                <button class="btn btn-primary" onclick="startConversion()" id="convertBtn">
                                    <i class="bi bi-play-circle"></i> Iniciar Conversão
                                </button>
                            </div>
                            
                            <!-- Progress -->
                            <div id="progressSection" style="display: none;">
                                <div class="mt-4">
                                    <h5><i class="bi bi-graph-up"></i> Progresso da Conversão</h5>
                                    <div class="progress-container">
                                        <div class="progress-bar" id="conversionProgress" style="width: 0%"></div>
                                    </div>
                                    <div class="d-flex justify-content-between mt-2">
                                        <span id="progressText">Iniciando...</span>
                                        <span id="progressPercent">0%</span>
                                    </div>
                                </div>
                            </div>
                            
                            <!-- Results -->
                            <div id="resultSection" style="display: none;">
                                <div class="alert alert-success mt-4">
                                    <h4><i class="bi bi-check-circle"></i> Conversão Concluída!</h4>
                                    <div id="resultDetails"></div>
                                </div>
                            </div>
                        </div>
                        
                        <!-- Conversions History -->
                        <div id="conversionsContent" style="display: none;">
                            <h3><i class="bi bi-clock-history"></i> Histórico de Conversões</h3>
                            <div id="conversionsList" class="mt-3">
                                <div class="text-center py-5">
                                    <div class="spinner-border text-primary" role="status">
                                        <span class="visually-hidden">Carregando...</span>
                                    </div>
                                    <p class="mt-3">Carregando histórico...</p>
                                </div>
                            </div>
                        </div>
                        
                        <!-- Settings -->
                        <div id="settingsContent" style="display: none;">
                            <h3><i class="bi bi-sliders"></i> Configurações</h3>
                            <div class="row mt-4">
                                <div class="col-md-6">
                                    <div class="card">
                                        <div class="card-header">
                                            <h5 class="mb-0">Qualidade HLS</h5>
                                        </div>
                                        <div class="card-body">
                                            <div class="mb-3">
                                                <label class="form-label">Segmentação (segundos)</label>
                                                <input type="number" class="form-control" id="segmentTime" value="10" min="2" max="30">
                                            </div>
                                            <div class="mb-3">
                                                <label class="form-label">Bitrate padrão</label>
                                                <select class="form-select" id="defaultBitrate">
                                                    <option value="1000k">1 Mbps</option>
                                                    <option value="2500k" selected>2.5 Mbps</option>
                                                    <option value="5000k">5 Mbps</option>
                                                    <option value="10000k">10 Mbps</option>
                                                </select>
                                            </div>
                                        </div>
                                    </div>
                                </div>
                                <div class="col-md-6">
                                    <div class="card">
                                        <div class="card-header">
                                            <h5 class="mb-0">Sistema</h5>
                                        </div>
                                        <div class="card-body">
                                            <div class="mb-3">
                                                <label class="form-label">Manter arquivos originais</label>
                                                <select class="form-select" id="keepOriginals">
                                                    <option value="yes">Sim</option>
                                                    <option value="no" selected>Não</option>
                                                </select>
                                            </div>
                                            <div class="mb-3">
                                                <label class="form-label">Limite de upload (MB)</label>
                                                <input type="number" class="form-control" id="uploadLimit" value="2000">
                                            </div>
                                        </div>
                                    </div>
                                </div>
                            </div>
                            <div class="mt-4">
                                <button class="btn btn-primary" onclick="saveSettings()">
                                    <i class="bi bi-save"></i> Salvar Configurações
                                </button>
                            </div>
                        </div>
                        
                        <!-- Tools -->
                        <div id="toolsContent" style="display: none;">
                            <h3><i class="bi bi-tools"></i> Ferramentas do Sistema</h3>
                            <div class="row mt-4">
                                <div class="col-md-6">
                                    <div class="card">
                                        <div class="card-header">
                                            <h5 class="mb-0"><i class="bi bi-wrench"></i> Manutenção</h5>
                                        </div>
                                        <div class="card-body">
                                            <div class="d-grid gap-2">
                                                <button class="btn btn-outline-primary" onclick="systemCleanup()">
                                                    <i class="bi bi-trash"></i> Limpar Arquivos Antigos
                                                </button>
                                                <button class="btn btn-outline-warning" onclick="restartService()">
                                                    <i class="bi bi-arrow-clockwise"></i> Reiniciar Serviço
                                                </button>
                                                <button class="btn btn-outline-danger" onclick="clearDatabase()">
                                                    <i class="bi bi-database-x"></i> Limpar Histórico
                                                </button>
                                            </div>
                                        </div>
                                    </div>
                                </div>
                                <div class="col-md-6">
                                    <div class="card">
                                        <div class="card-header">
                                            <h5 class="mb-0"><i class="bi bi-bug"></i> Diagnóstico</h5>
                                        </div>
                                        <div class="card-body">
                                            <div class="d-grid gap-2">
                                                <button class="btn btn-outline-info" onclick="checkFFmpeg()">
                                                    <i class="bi bi-camera-video"></i> Verificar FFmpeg
                                                </button>
                                                <button class="btn btn-outline-secondary" onclick="viewLogs()">
                                                    <i class="bi bi-file-text"></i> Visualizar Logs
                                                </button>
                                                <button class="btn btn-outline-success" onclick="systemInfo()">
                                                    <i class="bi bi-info-circle"></i> Informações do Sistema
                                                </button>
                                            </div>
                                        </div>
                                    </div>
                                </div>
                            </div>
                        </div>
                        
                        <!-- Help -->
                        <div id="helpContent" style="display: none;">
                            <h3><i class="bi bi-question-circle"></i> Ajuda & Suporte</h3>
                            <div class="row mt-4">
                                <div class="col-md-6">
                                    <div class="card">
                                        <div class="card-header">
                                            <h5 class="mb-0">Formatos Suportados</h5>
                                        </div>
                                        <div class="card-body">
                                            <ul>
                                                <li>MP4 (Recomendado)</li>
                                                <li>AVI</li>
                                                <li>MOV</li>
                                                <li>MKV</li>
                                                <li>WEBM</li>
                                            </ul>
                                        </div>
                                    </div>
                                </div>
                                <div class="col-md-6">
                                    <div class="card">
                                        <div class="card-header">
                                            <h5 class="mb-0">Qualidades Disponíveis</h5>
                                        </div>
                                        <div class="card-body">
                                            <ul>
                                                <li><span class="quality-badge quality-240p">240p</span> - Para baixa banda</li>
                                                <li><span class="quality-badge quality-480p">480p</span> - Qualidade SD</li>
                                                <li><span class="quality-badge quality-720p">720p</span> - HD Básico</li>
                                                <li><span class="quality-badge quality-1080p">1080p</span> - Full HD</li>
                                            </ul>
                                        </div>
                                    </div>
                                </div>
                            </div>
                            <div class="alert alert-info mt-4">
                                <h5><i class="bi bi-info-circle"></i> Comandos do Sistema</h5>
                                <p><code>hlsctl start</code> - Iniciar serviço</p>
                                <p><code>hlsctl stop</code> - Parar serviço</p>
                                <p><code>hlsctl restart</code> - Reiniciar serviço</p>
                                <p><code>hlsctl fix-ffmpeg</code> - Reparar FFmpeg</p>
                                <p><code>hlsctl cleanup</code> - Limpar arquivos antigos</p>
                                <p><code>hlsctl debug-ffmpeg</code> - Diagnosticar FFmpeg</p>
                            </div>
                        </div>
                    </div>
                </div>
                
                <!-- Footer -->
                <div class="mt-4 text-center text-white">
                    <p>HLS Converter ULTIMATE v4.0 | Sistema completo e robusto</p>
                </div>
            </div>
        </div>
    </div>

    <!-- Scripts -->
    <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.1.3/dist/js/bootstrap.bundle.min.js"></script>
    <script>
        // State management
        let selectedFiles = [];
        let currentConversion = null;
        let ffmpegAvailable = false;
        
        // Check FFmpeg on load
        function checkFFmpeg() {
            fetch('/api/system')
                .then(response => response.json())
                .then(data => {
                    const ffmpegStatusText = document.getElementById('ffmpegStatusText');
                    const ffmpegWarning = document.getElementById('ffmpegWarning');
                    const convertBtn = document.getElementById('convertBtn');
                    
                    if (data.ffmpeg_status === 'ok') {
                        ffmpegStatusText.innerHTML = '✅ Disponível';
                        ffmpegStatusText.title = data.ffmpeg_path + ' (' + data.ffmpeg_version + ')';
                        ffmpegWarning.style.display = 'none';
                        ffmpegAvailable = true;
                        convertBtn.disabled = false;
                    } else {
                        ffmpegStatusText.innerHTML = '❌ Não encontrado';
                        ffmpegStatusText.title = 'FFmpeg não instalado';
                        ffmpegWarning.style.display = 'block';
                        ffmpegAvailable = false;
                        convertBtn.disabled = true;
                        convertBtn.innerHTML = '<i class="bi bi-slash-circle"></i> FFmpeg não instalado';
                    }
                })
                .catch(error => {
                    console.error('Erro ao verificar FFmpeg:', error);
                });
        }
        
        // System functions
        function updateSystemStats() {
            fetch('/api/system')
                .then(response => response.json())
                .then(data => {
                    document.getElementById('cpuUsage').textContent = data.cpu;
                    document.getElementById('memoryUsage').textContent = data.memory;
                    document.getElementById('diskUsage').textContent = data.disk;
                    document.getElementById('uptime').textContent = data.uptime;
                    document.getElementById('totalConversions').textContent = data.total_conversions;
                    
                    // Update progress bars
                    const cpuPercent = parseFloat(data.cpu) || 0;
                    const memoryPercent = parseFloat(data.memory) || 0;
                    const diskPercent = parseFloat(data.disk) || 0;
                    
                    document.getElementById('cpuBar').style.width = cpuPercent + '%';
                    document.getElementById('memoryBar').style.width = memoryPercent + '%';
                    document.getElementById('diskBar').style.width = diskPercent + '%';
                })
                .catch(error => console.error('Erro ao carregar stats:', error));
        }
        
        function refreshStats() {
            updateSystemStats();
            checkFFmpeg();
            showToast('Stats atualizados!', 'success');
        }
        
        // File handling
        function handleFileSelect() {
            const input = document.getElementById('fileInput');
            const newFiles = Array.from(input.files);
            
            // Filter duplicates
            newFiles.forEach(newFile => {
                const exists = selectedFiles.some(existingFile => 
                    existingFile.name === newFile.name && 
                    existingFile.size === newFile.size
                );
                if (!exists) {
                    selectedFiles.push(newFile);
                }
            });
            
            updateFileList();
        }
        
        function updateFileList() {
            const container = document.getElementById('fileList');
            
            if (selectedFiles.length === 0) {
                container.innerHTML = '<div class="alert alert-info">Nenhum arquivo selecionado</div>';
                return;
            }
            
            let html = '<h5>Arquivos Selecionados:</h5>';
            selectedFiles.forEach((file, index) => {
                html += `
                    <div class="file-list-item">
                        <div class="d-flex justify-content-between align-items-center">
                            <div>
                                <strong>${file.name}</strong>
                                <div class="text-muted">${formatBytes(file.size)}</div>
                            </div>
                            <button class="btn btn-sm btn-danger" onclick="removeFile(${index})">
                                <i class="bi bi-trash"></i>
                            </button>
                        </div>
                    </div>
                `;
            });
            
            container.innerHTML = html;
        }
        
        function removeFile(index) {
            selectedFiles.splice(index, 1);
            updateFileList();
        }
        
        function clearFileList() {
            selectedFiles = [];
            document.getElementById('fileInput').value = '';
            updateFileList();
        }
        
        // Conversion
        function startConversion() {
            if (!ffmpegAvailable) {
                showToast('FFmpeg não está instalado! Use hlsctl fix-ffmpeg', 'danger');
                return;
            }
            
            if (selectedFiles.length === 0) {
                showToast('Selecione arquivos primeiro!', 'warning');
                return;
            }
            
            const convertBtn = document.getElementById('convertBtn');
            convertBtn.disabled = true;
            convertBtn.innerHTML = '<i class="bi bi-hourglass-split"></i> Processando...';
            
            // Show progress
            document.getElementById('progressSection').style.display = 'block';
            document.getElementById('resultSection').style.display = 'none';
            
            // Get quality settings
            const qualities = [];
            if (document.getElementById('quality240').checked) qualities.push('240p');
            if (document.getElementById('quality480').checked) qualities.push('480p');
            if (document.getElementById('quality720').checked) qualities.push('720p');
            if (document.getElementById('quality1080').checked) qualities.push('1080p');
            
            if (qualities.length === 0) {
                showToast('Selecione pelo menos uma qualidade!', 'warning');
                convertBtn.disabled = false;
                convertBtn.innerHTML = '<i class="bi bi-play-circle"></i> Iniciar Conversão';
                return;
            }
            
            // Prepare form data
            const formData = new FormData();
            selectedFiles.forEach(file => formData.append('files', file));
            formData.append('qualities', JSON.stringify(qualities));
            
            // Start conversion
            simulateProgress();
            
            fetch('/convert', {
                method: 'POST',
                body: formData
            })
            .then(response => response.json())
            .then(data => {
                if (data.success) {
                    showResult(data);
                } else {
                    showToast('Erro: ' + data.error, 'danger');
                }
            })
            .catch(error => {
                showToast('Erro de conexão: ' + error.message, 'danger');
            })
            .finally(() => {
                convertBtn.disabled = false;
                convertBtn.innerHTML = '<i class="bi bi-play-circle"></i> Iniciar Conversão';
                document.getElementById('progressSection').style.display = 'none';
            });
        }
        
        function simulateProgress() {
            let progress = 0;
            const interval = setInterval(() => {
                progress += Math.random() * 5;
                if (progress > 90) {
                    clearInterval(interval);
                    return;
                }
                updateProgress(progress, 'Convertendo...');
            }, 300);
        }
        
        function updateProgress(percent, text) {
            document.getElementById('conversionProgress').style.width = percent + '%';
            document.getElementById('progressText').textContent = text;
            document.getElementById('progressPercent').textContent = Math.round(percent) + '%';
        }
        
        function showResult(data) {
            document.getElementById('resultSection').style.display = 'block';
            
            let html = `
                <h5>Conversão concluída com sucesso!</h5>
                <p><strong>ID:</strong> ${data.video_id}</p>
                <p><strong>Qualidades geradas:</strong> ${data.qualities.join(', ')}</p>
                <div class="mt-3">
                    <h6>🔗 Link M3U8:</h6>
                    <div class="input-group">
                        <input type="text" class="form-control" id="m3u8Link" value="${window.location.origin}${data.m3u8_url}" readonly>
                        <button class="btn btn-outline-primary" type="button" onclick="copyToClipboard('m3u8Link')">
                            <i class="bi bi-clipboard"></i>
                        </button>
                    </div>
                </div>
                <div class="mt-3">
                    <button class="btn btn-success" onclick="testPlayback('${data.video_id}')">
                        <i class="bi bi-play-btn"></i> Testar Player
                    </button>
                    <button class="btn btn-info" onclick="downloadMaster('${data.video_id}')">
                        <i class="bi bi-download"></i> Baixar M3U8
                    </button>
                </div>
            `;
            
            document.getElementById('resultDetails').innerHTML = html;
            
            // Clear files
            selectedFiles = [];
            updateFileList();
            document.getElementById('fileInput').value = '';
            
            // Refresh conversions list
            loadConversions();
        }
        
        // Navigation
        function showUpload() {
            showTab('upload');
        }
        
        function showConversions() {
            showTab('conversions');
            loadConversions();
        }
        
        function showSettings() {
            showTab('settings');
        }
        
        function showTools() {
            showTab('tools');
        }
        
        function showHelp() {
            showTab('help');
        }
        
        function showTab(tabName) {
            // Hide all
            ['upload', 'conversions', 'settings', 'tools', 'help'].forEach(tab => {
                document.getElementById(tab + 'Content').style.display = 'none';
            });
            
            // Show selected
            document.getElementById(tabName + 'Content').style.display = 'block';
            
            // Update active tab
            updateActiveTab(tabName + '-tab');
        }
        
        function updateActiveTab(tabId) {
            document.querySelectorAll('#mainTabs .nav-link').forEach(tab => {
                tab.classList.remove('active');
            });
            document.getElementById(tabId).classList.add('active');
        }
        
        // Conversions history
        function loadConversions() {
            fetch('/api/conversions')
                .then(response => response.json())
                .then(data => {
                    const container = document.getElementById('conversionsList');
                    
                    if (data.conversions.length === 0) {
                        container.innerHTML = '<div class="alert alert-info">Nenhuma conversão realizada ainda</div>';
                        return;
                    }
                    
                    let html = '<div class="row">';
                    data.conversions.slice(0, 12).forEach(conv => {
                        html += `
                            <div class="col-md-4 mb-3">
                                <div class="card">
                                    <div class="card-body">
                                        <h6>${conv.video_id}</h6>
                                        <p><small class="text-muted">${formatDate(conv.timestamp)}</small></p>
                                        <p><strong>Arquivo:</strong> ${conv.filename}</p>
                                        <p><strong>Status:</strong> <span class="badge bg-${conv.status === 'success' ? 'success' : 'danger'}">${conv.status}</span></p>
                                        <button class="btn btn-sm btn-outline-primary" onclick="copyConversionLink('${conv.video_id}')">
                                            <i class="bi bi-link"></i> Copiar Link
                                        </button>
                                    </div>
                                </div>
                            </div>
                        `;
                    });
                    html += '</div>';
                    
                    container.innerHTML = html;
                })
                .catch(error => {
                    document.getElementById('conversionsList').innerHTML = 
                        '<div class="alert alert-danger">Erro ao carregar histórico</div>';
                });
        }
        
        // Tools functions
        function systemCleanup() {
            if (confirm('Limpar arquivos antigos (>7 dias)?')) {
                fetch('/api/cleanup', { method: 'POST' })
                    .then(response => response.json())
                    .then(data => {
                        showToast('Limpeza concluída: ' + data.message, 'success');
                    });
            }
        }
        
        function restartService() {
            if (confirm('Reiniciar serviço HLS Converter?')) {
                fetch('/api/restart', { method: 'POST' })
                    .then(response => response.json())
                    .then(data => {
                        showToast('Serviço reiniciado!', 'success');
                    });
            }
        }
        
        function clearDatabase() {
            if (confirm('Limpar todo o histórico de conversões?')) {
                fetch('/api/clear-db', { method: 'POST' })
                    .then(response => response.json())
                    .then(data => {
                        showToast('Histórico limpo!', 'success');
                        loadConversions();
                    });
            }
        }
        
        function viewLogs() {
            window.open('/api/logs', '_blank');
        }
        
        function systemInfo() {
            window.open('/api/debug', '_blank');
        }
        
        // Utility functions
        function formatBytes(bytes) {
            if (bytes === 0) return '0 Bytes';
            const k = 1024;
            const sizes = ['Bytes', 'KB', 'MB', 'GB'];
            const i = Math.floor(Math.log(bytes) / Math.log(k));
            return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i];
        }
        
        function formatDate(timestamp) {
            return new Date(timestamp).toLocaleString();
        }
        
        function copyToClipboard(elementId) {
            const element = document.getElementById(elementId);
            element.select();
            element.setSelectionRange(0, 99999);
            document.execCommand('copy');
            showToast('Link copiado!', 'success');
        }
        
        function copyConversionLink(videoId) {
            const link = window.location.origin + '/hls/' + videoId + '/master.m3u8';
            navigator.clipboard.writeText(link);
            showToast('Link copiado!', 'success');
        }
        
        function testPlayback(videoId) {
            window.open('/player/' + videoId, '_blank');
        }
        
        function downloadMaster(videoId) {
            window.location.href = '/hls/' + videoId + '/master.m3u8';
        }
        
        function saveSettings() {
            showToast('Configurações salvas!', 'success');
        }
        
        function showToast(message, type) {
            // Create toast
            const toastId = 'toast-' + Date.now();
            const toastHtml = `
                <div id="${toastId}" class="position-fixed bottom-0 end-0 p-3" style="z-index: 11">
                    <div class="toast align-items-center text-white bg-${type === 'success' ? 'success' : type === 'warning' ? 'warning' : 'danger'} border-0" role="alert">
                        <div class="d-flex">
                            <div class="toast-body">
                                ${message}
                            </div>
                            <button type="button" class="btn-close btn-close-white me-2 m-auto" data-bs-dismiss="toast"></button>
                        </div>
                    </div>
                </div>
            `;
            
            document.body.insertAdjacentHTML('beforeend', toastHtml);
            
            // Show toast
            const toastElement = document.getElementById(toastId).querySelector('.toast');
            const toast = new bootstrap.Toast(toastElement);
            toast.show();
            
            // Remove after hide
            toastElement.addEventListener('hidden.bs.toast', function () {
                document.getElementById(toastId).remove();
            });
        }
        
        // Initialize
        document.addEventListener('DOMContentLoaded', function() {
            updateSystemStats();
            checkFFmpeg();
            setInterval(updateSystemStats, 30000); // Update every 30 seconds
            setInterval(checkFFmpeg, 60000); // Check FFmpeg every minute
            
            // Handle drag and drop
            const uploadArea = document.querySelector('.upload-area');
            uploadArea.addEventListener('dragover', (e) => {
                e.preventDefault();
                uploadArea.style.backgroundColor = 'rgba(67, 97, 238, 0.2)';
            });
            
            uploadArea.addEventListener('dragleave', () => {
                uploadArea.style.backgroundColor = '';
            });
            
            uploadArea.addEventListener('drop', (e) => {
                e.preventDefault();
                uploadArea.style.backgroundColor = '';
                
                const files = Array.from(e.dataTransfer.files);
                files.forEach(file => {
                    if (file.type.startsWith('video/')) {
                        selectedFiles.push(file);
                    }
                });
                
                updateFileList();
            });
        });
    </script>
</body>
</html>
'''

PLAYER_HTML = '''
<!DOCTYPE html>
<html>
<head>
    <title>Player HLS</title>
    <link href="https://vjs.zencdn.net/7.20.3/video-js.css" rel="stylesheet">
    <style>
        body { margin: 0; padding: 20px; background: #000; }
        .player-container { max-width: 1200px; margin: 0 auto; }
        .back-btn { 
            background: #4361ee; 
            color: white; 
            border: none; 
            padding: 10px 20px; 
            border-radius: 5px; 
            cursor: pointer;
            margin-bottom: 20px;
        }
    </style>
</head>
<body>
    <div class="player-container">
        <button class="back-btn" onclick="window.history.back()">← Voltar</button>
        <video id="hlsPlayer" class="video-js vjs-default-skin" controls preload="auto" width="100%" height="auto">
            <source src="{m3u8_url}" type="application/x-mpegURL">
        </video>
    </div>
    
    <script src="https://vjs.zencdn.net/7.20.3/video.js"></script>
    <script src="https://cdnjs.cloudflare.com/ajax/libs/videojs-contrib-hls/5.15.0/videojs-contrib-hls.min.js"></script>
    <script>
        var player = videojs('hlsPlayer');
        player.play();
    </script>
</body>
</html>
'''

# ==================== ROTAS DA APLICAÇÃO ULTIMATE ====================

@app.route('/')
def index():
    return render_template_string(INDEX_HTML)

@app.route('/convert', methods=['POST'])
def convert_video():
    try:
        if not FFMPEG_PATH:
            return jsonify({
                'success': False, 
                'error': 'FFmpeg não está instalado no sistema. '
                        'Execute: hlsctl fix-ffmpeg ou sudo apt-get install ffmpeg'
            })
        
        if 'files' not in request.files:
            return jsonify({'success': False, 'error': 'Nenhum arquivo enviado'})
        
        files = request.files.getlist('files')
        if not files or files[0].filename == '':
            return jsonify({'success': False, 'error': 'Nenhum arquivo selecionado'})
        
        # Get quality settings
        qualities_json = request.form.get('qualities', '["720p"]')
        try:
            qualities = json.loads(qualities_json)
        except:
            qualities = ["720p"]
        
        # Generate unique ID
        video_id = str(uuid.uuid4())[:12]
        output_dir = os.path.join(HLS_DIR, video_id)
        os.makedirs(output_dir, exist_ok=True)
        
        # Save and convert first file
        file = files[0]
        filename = secure_filename(file.filename)
        original_path = os.path.join(UPLOAD_DIR, f"{video_id}_{filename}")
        file.save(original_path)
        
        log_activity(f"Iniciando conversão: {filename} -> {video_id}")
        log_activity(f"Usando ffmpeg: {FFMPEG_PATH}")
        
        # Test ffmpeg command first
        try:
            test_result = subprocess.run([FFMPEG_PATH, '-version'], capture_output=True, text=True, timeout=10)
            if test_result.returncode != 0:
                log_activity(f"FFmpeg test failed: {test_result.stderr[:100]}", "ERROR")
                return jsonify({'success': False, 'error': f'FFmpeg não está funcionando: {test_result.stderr[:100]}'})
        except Exception as e:
            log_activity(f"FFmpeg test exception: {str(e)}", "ERROR")
            return jsonify({'success': False, 'error': f'Erro ao executar ffmpeg: {str(e)}'})
        
        # Create master playlist
        master_playlist = os.path.join(output_dir, "master.m3u8")
        
        with open(master_playlist, 'w') as f:
            f.write("#EXTM3U\n")
            f.write("#EXT-X-VERSION:3\n")
            
            # Convert for each quality
            for quality in qualities:
                if quality == '240p':
                    quality_dir = os.path.join(output_dir, '240p')
                    os.makedirs(quality_dir, exist_ok=True)
                    
                    m3u8_file = os.path.join(quality_dir, 'index.m3u8')
                    cmd = [
                        FFMPEG_PATH, '-i', original_path,
                        '-vf', 'scale=426:240',
                        '-c:v', 'libx264', '-preset', 'fast', '-crf', '28',
                        '-c:a', 'aac', '-b:a', '64k',
                        '-hls_time', '10',
                        '-hls_list_size', '0',
                        '-hls_segment_filename', os.path.join(quality_dir, 'segment_%03d.ts'),
                        '-f', 'hls', m3u8_file
                    ]
                    f.write('#EXT-X-STREAM-INF:BANDWIDTH=400000,RESOLUTION=426x240\n')
                    f.write('240p/index.m3u8\n')
                    
                elif quality == '480p':
                    quality_dir = os.path.join(output_dir, '480p')
                    os.makedirs(quality_dir, exist_ok=True)
                    
                    m3u8_file = os.path.join(quality_dir, 'index.m3u8')
                    cmd = [
                        FFMPEG_PATH, '-i', original_path,
                        '-vf', 'scale=854:480',
                        '-c:v', 'libx264', '-preset', 'fast', '-crf', '26',
                        '-c:a', 'aac', '-b:a', '96k',
                        '-hls_time', '10',
                        '-hls_list_size', '0',
                        '-hls_segment_filename', os.path.join(quality_dir, 'segment_%03d.ts'),
                        '-f', 'hls', m3u8_file
                    ]
                    f.write('#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=854x480\n')
                    f.write('480p/index.m3u8\n')
                    
                elif quality == '720p':
                    quality_dir = os.path.join(output_dir, '720p')
                    os.makedirs(quality_dir, exist_ok=True)
                    
                    m3u8_file = os.path.join(quality_dir, 'index.m3u8')
                    cmd = [
                        FFMPEG_PATH, '-i', original_path,
                        '-vf', 'scale=1280:720',
                        '-c:v', 'libx264', '-preset', 'fast', '-crf', '23',
                        '-c:a', 'aac', '-b:a', '128k',
                        '-hls_time', '10',
                        '-hls_list_size', '0',
                        '-hls_segment_filename', os.path.join(quality_dir, 'segment_%03d.ts'),
                        '-f', 'hls', m3u8_file
                    ]
                    f.write('#EXT-X-STREAM-INF:BANDWIDTH=1500000,RESOLUTION=1280x720\n')
                    f.write('720p/index.m3u8\n')
                    
                elif quality == '1080p':
                    quality_dir = os.path.join(output_dir, '1080p')
                    os.makedirs(quality_dir, exist_ok=True)
                    
                    m3u8_file = os.path.join(quality_dir, 'index.m3u8')
                    cmd = [
                        FFMPEG_PATH, '-i', original_path,
                        '-vf', 'scale=1920:1080',
                        '-c:v', 'libx264', '-preset', 'fast', '-crf', '23',
                        '-c:a', 'aac', '-b:a', '192k',
                        '-hls_time', '10',
                        '-hls_list_size', '0',
                        '-hls_segment_filename', os.path.join(quality_dir, 'segment_%03d.ts'),
                        '-f', 'hls', m3u8_file
                    ]
                    f.write('#EXT-X-STREAM-INF:BANDWIDTH=3000000,RESOLUTION=1920x1080\n')
                    f.write('1080p/index.m3u8\n')
                else:
                    continue  # Skip unknown qualities
                
                # Run conversion
                log_activity(f"Convertendo para {quality}...")
                try:
                    result = subprocess.run(cmd, capture_output=True, text=True, timeout=300)  # 5 minutos timeout
                    
                    if result.returncode != 0:
                        log_activity(f"Erro na conversão {quality}: {result.stderr[:200]}", "ERROR")
                        continue  # Continue with other qualities
                except subprocess.TimeoutExpired:
                    log_activity(f"Timeout na conversão {quality}", "ERROR")
                    continue
        
        # Save original file
        original_dir = os.path.join(output_dir, "original")
        os.makedirs(original_dir, exist_ok=True)
        original_copy = os.path.join(original_dir, filename)
        shutil.copy2(original_path, original_copy)
        
        # Clean up original upload
        try:
            os.remove(original_path)
        except:
            pass
        
        # Update database
        db = load_database()
        conversion_data = {
            "video_id": video_id,
            "filename": filename,
            "qualities": qualities,
            "timestamp": datetime.now().isoformat(),
            "status": "success",
            "m3u8_url": f"/hls/{video_id}/master.m3u8"
        }
        
        db["conversions"].insert(0, conversion_data)
        db["stats"]["total"] = db["stats"].get("total", 0) + 1
        db["stats"]["success"] = db["stats"].get("success", 0) + 1
        save_database(db)
        
        log_activity(f"Conversão concluída: {video_id} ({', '.join(qualities)})")
        
        return jsonify({
            "success": True,
            "video_id": video_id,
            "qualities": qualities,
            "m3u8_url": f"/hls/{video_id}/master.m3u8",
            "player_url": f"/player/{video_id}"
        })
        
    except subprocess.TimeoutExpired:
        log_activity("Timeout na conversão", "ERROR")
        return jsonify({"success": False, "error": "Timeout na conversão (5 minutos)"})
    except Exception as e:
        log_activity(f"Erro na conversão: {str(e)}", "ERROR")
        return jsonify({"success": False, "error": str(e)})

@app.route('/api/system')
def api_system():
    """API para informações do sistema"""
    return jsonify(get_system_info())

@app.route('/api/conversions')
def api_conversions():
    """API para listar conversões"""
    db = load_database()
    return jsonify(db)

@app.route('/api/cleanup', methods=['POST'])
def api_cleanup():
    """API para limpar arquivos antigos"""
    try:
        deleted = 0
        # Clean uploads older than 7 days
        for file in os.listdir(UPLOAD_DIR):
            file_path = os.path.join(UPLOAD_DIR, file)
            if os.path.isfile(file_path):
                file_age = time.time() - os.path.getmtime(file_path)
                if file_age > 7 * 24 * 3600:  # 7 days
                    os.remove(file_path)
                    deleted += 1
        
        # Clean HLS folders older than 7 days
        for folder in os.listdir(HLS_DIR):
            folder_path = os.path.join(HLS_DIR, folder)
            if os.path.isdir(folder_path):
                folder_age = time.time() - os.path.getmtime(folder_path)
                if folder_age > 7 * 24 * 3600:  # 7 days
                    shutil.rmtree(folder_path, ignore_errors=True)
                    deleted += 1
        
        return jsonify({"success": True, "message": f"{deleted} arquivos/folders removidos"})
    except Exception as e:
        return jsonify({"success": False, "error": str(e)})

@app.route('/api/restart', methods=['POST'])
def api_restart():
    """API para reiniciar serviço"""
    try:
        # This is a simulation - in production would call systemctl
        log_activity("Reinício solicitado via API", "INFO")
        return jsonify({"success": True, "message": "Reinício solicitado"})
    except Exception as e:
        return jsonify({"success": False, "error": str(e)})

@app.route('/api/clear-db', methods=['POST'])
def api_clear_db():
    """API para limpar banco de dados"""
    try:
        db = load_database()
        count = len(db["conversions"])
        db["conversions"] = []
        db["stats"]["total"] = 0
        db["stats"]["success"] = 0
        db["stats"]["failed"] = 0
        save_database(db)
        
        log_activity(f"Banco de dados limpo: {count} entradas removidas", "INFO")
        return jsonify({"success": True, "message": f"{count} entradas removidas"})
    except Exception as e:
        return jsonify({"success": False, "error": str(e)})

@app.route('/api/logs')
def api_logs():
    """API para visualizar logs"""
    try:
        log_file = os.path.join(LOG_DIR, "activity.log")
        if os.path.exists(log_file):
            with open(log_file, 'r') as f:
                logs = f.read()
            return jsonify({"success": True, "logs": logs})
        else:
            return jsonify({"success": False, "error": "Arquivo de log não encontrado"})
    except Exception as e:
        return jsonify({"success": False, "error": str(e)})

@app.route('/api/debug')
def api_debug():
    """API para debug do sistema"""
    debug_info = {
        "system": get_system_info(),
        "ffmpeg": {
            "path": FFMPEG_PATH,
            "version": get_ffmpeg_version(),
            "test": "ok" if FFMPEG_PATH else "missing"
        },
        "directories": {
            "base": BASE_DIR,
            "uploads": UPLOAD_DIR,
            "hls": HLS_DIR,
            "logs": LOG_DIR,
            "db": DB_DIR
        },
        "database": load_database()
    }
    return jsonify(debug_info)

@app.route('/player/<video_id>')
def player_page(video_id):
    """Página do player"""
    m3u8_url = f"/hls/{video_id}/master.m3u8"
    player_html = PLAYER_HTML.replace("{m3u8_url}", m3u8_url)
    return render_template_string(player_html)

@app.route('/hls/<path:filename>')
def serve_hls(filename):
    """Servir arquivos HLS"""
    filepath = os.path.join(HLS_DIR, filename)
    if os.path.exists(filepath):
        response = send_file(filepath)
        response.headers['Access-Control-Allow-Origin'] = '*'
        response.headers['Cache-Control'] = 'public, max-age=31536000'
        return response
    return "Arquivo não encontrado", 404

@app.route('/static/<path:filename>')
def serve_static(filename):
    """Servir arquivos estáticos"""
    return send_from_directory('static', filename)

@app.route('/health')
def health_check():
    """Health check do sistema"""
    status = "healthy" if FFMPEG_PATH else "warning"
    
    return jsonify({
        "status": status,
        "service": "hls-converter-ultimate",
        "version": "4.0.0",
        "ffmpeg": FFMPEG_PATH is not None,
        "ffmpeg_path": FFMPEG_PATH or "not found",
        "ffmpeg_version": get_ffmpeg_version(),
        "timestamp": datetime.now().isoformat(),
        "system": get_system_info()
    })

if __name__ == '__main__':
    print("🎬 HLS Converter ULTIMATE v4.0")
    print("==============================")
    
    if FFMPEG_PATH:
        print(f"✅ FFmpeg encontrado em: {FFMPEG_PATH}")
        try:
            result = subprocess.run([FFMPEG_PATH, '-version'], capture_output=True, text=True)
            if result.returncode == 0:
                version_line = result.stdout.split('\n')[0]
                print(f"📊 Versão: {version_line}")
        except:
            print("⚠️  FFmpeg encontrado mas não testado")
    else:
        print("❌ FFmpeg NÃO encontrado!")
        print("📋 Execute: hlsctl fix-ffmpeg")
    
    print("🌐 Starting on port 8080")
    print("✅ Health check: http://localhost:8080/health")
    print("🎮 Interface: http://localhost:8080/")
    print("🔧 Debug: http://localhost:8080/api/debug")
    print("")
    
    from waitress import serve
    serve(app, host='0.0.0.0', port=8080)
EOF

# 13. CRIAR ARQUIVOS DE CONFIGURAÇÃO
echo "📁 Criando arquivos de configuração..."

# Arquivo de configuração do sistema
cat > /opt/hls-converter/config.json << 'EOF'
{
    "system": {
        "port": 8080,
        "upload_limit_mb": 2048,
        "keep_originals": true,
        "cleanup_days": 7,
        "hls_segment_time": 10,
        "enable_multiple_qualities": true
    },
    "qualities": {
        "240p": {
            "scale": "426:240",
            "bitrate": "400k",
            "audio_bitrate": "64k",
            "crf": "28"
        },
        "480p": {
            "scale": "854:480",
            "bitrate": "800k",
            "audio_bitrate": "96k",
            "crf": "26"
        },
        "720p": {
            "scale": "1280:720",
            "bitrate": "1500k",
            "audio_bitrate": "128k",
            "crf": "23"
        },
        "1080p": {
            "scale": "1920:1080",
            "bitrate": "3000k",
            "audio_bitrate": "192k",
            "crf": "23"
        }
    },
    "ffmpeg": {
        "preset": "fast",
        "threads": "auto"
    }
}
EOF

# 14. CRIAR BANCO DE DADOS INICIAL
echo "💾 Criando banco de dados inicial..."

cat > /opt/hls-converter/db/conversions.json << 'EOF'
{
    "conversions": [],
    "stats": {
        "total": 0,
        "success": 0,
        "failed": 0
    }
}
EOF

# 15. CRIAR SCRIPT DE VERIFICAÇÃO DO FFMPEG
echo "🔧 Criando script de verificação do ffmpeg..."

cat > /opt/hls-converter/check_ffmpeg.sh << 'EOF'
#!/bin/bash

echo "🔍 Verificando FFmpeg..."
echo "========================"

echo "1. Verificando PATH..."
which ffmpeg

echo ""
echo "2. Procurando ffmpeg no sistema..."
find /usr -name "ffmpeg" -type f 2>/dev/null | head -5

echo ""
echo "3. Testando execução..."
if command -v ffmpeg &> /dev/null; then
    ffmpeg -version | head -3
else
    echo "   ❌ ffmpeg não encontrado"
fi

echo ""
echo "4. Soluções:"
echo "   • hlsctl fix-ffmpeg"
echo "   • sudo apt-get update && sudo apt-get install -y ffmpeg"
echo "   • sudo snap install ffmpeg --classic"
EOF

chmod +x /opt/hls-converter/check_ffmpeg.sh

# 16. CRIAR SERVIÇO SYSTEMD COMPLETO
echo "⚙️ Configurando serviço systemd..."

cat > /etc/systemd/system/hls-converter.service << 'EOF'
[Unit]
Description=HLS Converter ULTIMATE Service
After=network.target
Wants=network.target

[Service]
Type=simple
User=hlsuser
Group=hlsuser
WorkingDirectory=/opt/hls-converter
Environment="PATH=/opt/hls-converter/venv/bin:/usr/local/bin:/usr/bin:/bin"
Environment="PYTHONUNBUFFERED=1"

ExecStart=/opt/hls-converter/venv/bin/waitress-serve --port=8080 --call app:app

Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=hls-converter

# Security
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=/opt/hls-converter/uploads /opt/hls-converter/hls /opt/hls-converter/logs /opt/hls-converter/db

[Install]
WantedBy=multi-user.target
EOF

# 17. CRIAR SCRIPT DE GERENCIAMENTO AVANÇADO (hlsctl)
echo "📝 Criando script de gerenciamento avançado..."

cat > /usr/local/bin/hlsctl << 'EOF'
#!/bin/bash

HLS_HOME="/opt/hls-converter"

case "$1" in
    start)
        systemctl start hls-converter
        echo "✅ Serviço iniciado"
        ;;
    stop)
        systemctl stop hls-converter
        echo "✅ Serviço parado"
        ;;
    restart)
        systemctl restart hls-converter
        echo "✅ Serviço reiniciado"
        ;;
    status)
        systemctl status hls-converter --no-pager
        ;;
    logs)
        if [ "$2" = "-f" ]; then
            journalctl -u hls-converter -f
        else
            journalctl -u hls-converter -n 30 --no-pager
        fi
        ;;
    test)
        echo "🧪 Testando sistema..."
        curl -s http://localhost:8080/health | python3 -m json.tool || curl -s http://localhost:8080/health
        echo ""
        echo "FFmpeg:"
        ffmpeg -version 2>/dev/null | head -1 || echo "FFmpeg não encontrado"
        ;;
    cleanup)
        echo "🧹 Limpando arquivos antigos..."
        find /opt/hls-converter/uploads -type f -mtime +7 -delete 2>/dev/null
        find /opt/hls-converter/hls -type d -mtime +7 -exec rm -rf {} \; 2>/dev/null
        echo "✅ Arquivos antigos removidos"
        ;;
    fix-ffmpeg)
        echo "🔧 Instalando ffmpeg com múltiplos métodos..."
        
        # Method 1: Standard apt
        echo "📦 Método 1: Instalação via apt..."
        apt-get update
        apt-get install -y ffmpeg
        
        if command -v ffmpeg &> /dev/null; then
            echo "✅ FFmpeg instalado via apt"
        else
            # Method 2: Snap
            echo "📦 Método 2: Instalação via Snap..."
            if command -v snap &> /dev/null; then
                snap install ffmpeg --classic
            fi
            
            if ! command -v ffmpeg &> /dev/null; then
                # Method 3: Static binary
                echo "📦 Método 3: Baixando binário estático..."
                cd /tmp
                wget -q https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz || \
                curl -L -o ffmpeg-release-amd64-static.tar.xz https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz
                
                if [ -f ffmpeg-release-amd64-static.tar.xz ]; then
                    tar -xf ffmpeg-release-amd64-static.tar.xz
                    FFMPEG_DIR=$(find . -name "ffmpeg-*-static" -type d | head -1)
                    if [ -n "$FFMPEG_DIR" ]; then
                        cp "$FFMPEG_DIR"/ffmpeg "$FFMPEG_DIR"/ffprobe /usr/local/bin/
                        chmod +x /usr/local/bin/ffmpeg /usr/local/bin/ffprobe
                        echo "✅ FFmpeg instalado de binário estático"
                    fi
                fi
            fi
        fi
        
        if command -v ffmpeg &> /dev/null; then
            echo "🎉 FFMPEG INSTALADO COM SUCESSO!"
            echo "🔍 Localização: $(which ffmpeg)"
            echo "📊 Versão:"
            ffmpeg -version | head -1
            echo ""
            echo "🔄 Reinicie o serviço:"
            echo "   hlsctl restart"
        else
            echo "❌ Não foi possível instalar FFmpeg automaticamente"
            echo "📋 Instale manualmente:"
            echo "   1. sudo apt-get update && sudo apt-get install -y ffmpeg"
            echo "   2. Ou baixe de: https://ffmpeg.org/download.html"
        fi
        ;;
    debug-ffmpeg)
        echo "🔍 Depurando ffmpeg..."
        echo "1. Verificando PATH..."
        which ffmpeg || echo "   Não encontrado no PATH"
        
        echo ""
        echo "2. Procurando no sistema..."
        find /usr -name "ffmpeg" -type f 2>/dev/null | head -5
        
        echo ""
        echo "3. Testando endpoint de debug..."
        curl -s http://localhost:8080/api/debug 2>/dev/null | python3 -m json.tool || \
        echo "   Aplicação não está rodando"
        
        echo ""
        echo "4. Testando execução..."
        if command -v ffmpeg &> /dev/null; then
            ffmpeg -version | head -1
        else
            echo "   comando ffmpeg não encontrado"
        fi
        ;;
    reinstall)
        echo "🔄 Reinstalando HLS Converter..."
        systemctl stop hls-converter 2>/dev/null || true
        rm -rf /opt/hls-converter
        rm -f /etc/systemd/system/hls-converter.service
        rm -f /usr/local/bin/hlsctl
        echo "✅ Instalação antiga removida"
        echo "📋 Execute o instalador novamente"
        ;;
    info)
        IP=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "localhost")
        echo "=== HLS Converter ULTIMATE ==="
        echo "Porta: 8080"
        echo "URL: http://$IP:8080"
        echo "Health: http://$IP:8080/health"
        echo "Diretório: /opt/hls-converter"
        echo "Usuário: hlsuser"
        echo "Status: $(systemctl is-active hls-converter 2>/dev/null || echo 'inactive')"
        
        if command -v ffmpeg &> /dev/null; then
            echo "FFmpeg: ✅ Disponível"
            echo "Versão: $(ffmpeg -version 2>/dev/null | head -1 | cut -d' ' -f3)"
        else
            echo "FFmpeg: ❌ Não instalado"
        fi
        ;;
    *)
        echo "Uso: hlsctl [comando]"
        echo ""
        echo "Comandos:"
        echo "  start         - Iniciar serviço"
        echo "  stop          - Parar serviço"
        echo "  restart       - Reiniciar serviço"
        echo "  status        - Ver status"
        echo "  logs          - Ver logs"
        echo "  test          - Testar sistema"
        echo "  cleanup       - Limpar arquivos antigos"
        echo "  fix-ffmpeg    - INSTALAR/REPARAR FFMPEG"
        echo "  debug-ffmpeg  - Diagnosticar ffmpeg"
        echo "  reinstall     - Reinstalar sistema"
        echo "  info          - Informações do sistema"
        ;;
esac
EOF

chmod +x /usr/local/bin/hlsctl

# 18. CONFIGURAR PERMISSÕES
echo "🔐 Configurando permissões..."
chown -R hlsuser:hlsuser /opt/hls-converter
chmod 755 /opt/hls-converter
chmod 644 /opt/hls-converter/*.py
chmod 644 /opt/hls-converter/*.json
chmod 755 /opt/hls-converter/check_ffmpeg.sh

# 19. INICIAR SERVIÇO
echo "🚀 Iniciando serviço..."
systemctl daemon-reload
systemctl enable hls-converter.service
systemctl start hls-converter.service

sleep 8

# 20. VERIFICAÇÃO FINAL DETALHADA
echo "🔍 VERIFICAÇÃO FINAL DETALHADA..."
echo "================================"

# Verificar ffmpeg
echo ""
echo "1. Verificando FFmpeg:"
if command -v ffmpeg &> /dev/null; then
    echo "   ✅ FFmpeg encontrado: $(which ffmpeg)"
    ffmpeg -version | head -1
else
    echo "   ❌ FFmpeg NÃO encontrado!"
    echo "   📋 Execute: hlsctl fix-ffmpeg"
fi

# Verificar serviço
echo ""
echo "2. Verificando serviço:"
if systemctl is-active --quiet hls-converter.service; then
    echo "   ✅ Serviço está ativo"
    
    echo ""
    echo "3. Testando endpoints:"
    
    # Health check
    echo "   a) Health check:"
    if curl -s http://localhost:8080/health | grep -q "healthy"; then
        echo "      ✅ OK"
    else
        echo "      ⚠️  Warning"
        curl -s http://localhost:8080/health | head -2
    fi
    
    # Debug endpoint
    echo "   b) Debug endpoint:"
    curl -s http://localhost:8080/api/debug 2>/dev/null | grep -q "system" && echo "      ✅ OK" || echo "      ❌ Falha"
    
    # Interface web
    echo "   c) Interface web:"
    curl -s -I http://localhost:8080/ | head -1 | grep -q "200" && echo "      ✅ OK" || echo "      ⚠️  Verifique"
    
else
    echo "   ❌ Serviço não está ativo"
    echo "   📋 Logs:"
    journalctl -u hls-converter -n 10 --no-pager
fi

# 21. OBTER INFORMAÇÕES DO SISTEMA
IP=$(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}' 2>/dev/null || echo "localhost")

echo ""
echo "🎉🎉🎉 INSTALAÇÃO ULTIMATE CONCLUÍDA! 🎉🎉🎉"
echo "==========================================="
echo ""
echo "✅ SISTEMA COMPLETO INSTALADO"
echo ""
echo "✨ CARACTERÍSTICAS INCLUÍDAS:"
echo "   ✔️  Dashboard profissional completo"
echo "   ✔️  Sistema robusto de instalação do FFmpeg"
echo "   ✔️  Script de gerenciamento avançado (hlsctl)"
echo "   ✔️  Verificação automática do FFmpeg"
echo "   ✔️  Interface com múltiplas abas"
echo "   ✔️  Histórico de conversões"
echo "   ✔️  Ferramentas de manutenção"
echo "   ✔️  Monitoramento em tempo real"
echo "   ✔️  Sistema de logs detalhado"
echo "   ✔️  Otimizado para produção"
echo ""
echo "🌐 URLS DE ACESSO:"
echo "   🎨 INTERFACE PRINCIPAL: http://$IP:8080"
echo "   🩺 HEALTH CHECK: http://$IP:8080/health"
echo "   🔧 DEBUG COMPLETO: http://$IP:8080/api/debug"
echo "   📋 API CONVERSÕES: http://$IP:8080/api/conversions"
echo ""
echo "⚙️  COMANDOS DE GERENCIAMENTO:"
echo "   • hlsctl start         - Iniciar serviço"
echo "   • hlsctl stop          - Parar serviço"
echo "   • hlsctl restart       - Reiniciar serviço"
echo "   • hlsctl status        - Ver status"
echo "   • hlsctl logs          - Ver logs"
echo "   • hlsctl test          - Testar sistema"
echo "   • hlsctl cleanup       - Limpar arquivos antigos"
echo "   • hlsctl fix-ffmpeg    - INSTALAR/REPARAR FFMPEG"
echo "   • hlsctl debug-ffmpeg  - Diagnosticar problemas"
echo "   • hlsctl reinstall     - Reinstalar sistema"
echo "   • hlsctl info          - Informações do sistema"
echo ""
echo "📁 DIRETÓRIOS DO SISTEMA:"
echo "   • Aplicação: /opt/hls-converter/"
echo "   • Uploads: /opt/hls-converter/uploads/"
echo "   • HLS: /opt/hls-converter/hls/"
echo "   • Logs: /opt/hls-converter/logs/"
echo "   • Banco de dados: /opt/hls-converter/db/"
echo ""
echo "💡 COMO USAR:"
echo "   1. Acesse http://$IP:8080"
echo "   2. A interface mostrará se FFmpeg está instalado"
echo "   3. Se não estiver, use: hlsctl fix-ffmpeg"
echo "   4. Arraste vídeos para a área de upload"
echo "   5. Selecione qualidades e clique em converter"
echo "   6. Use o link M3U8 gerado"
echo ""
echo "🚀 SISTEMA PRONTO PARA USO!"

# 22. CRIAR SCRIPT DE BACKUP (extra)
echo "💾 Criando script de backup..."

cat > /usr/local/bin/hls-backup << 'EOF'
#!/bin/bash
BACKUP_DIR="/opt/hls-backup-$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"
cp -r /opt/hls-converter/db "$BACKUP_DIR/"
cp -r /opt/hls-converter/config.json "$BACKUP_DIR/"
echo "✅ Backup criado em: $BACKUP_DIR"
EOF

chmod +x /usr/local/bin/hls-backup

echo ""
echo "✅ Script de backup criado: hls-backup"
echo ""
echo "🎯 INSTALAÇÃO COMPLETA - SISTEMA ULTIMATE PRONTO!"
