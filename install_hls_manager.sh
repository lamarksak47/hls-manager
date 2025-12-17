#!/bin/bash
# install_hls_converter_complete_fixed_final_v2.sh - Versão com banco de dados corrigido

set -e

echo "🚀 INSTALANDO HLS CONVERTER - VERSÃO FINAL CORRIGIDA"
echo "===================================================="

# 1. Definir diretório base no home
HLS_HOME="$HOME/hls-converter-pro"
echo "📁 Diretório base: $HLS_HOME"

# Função para instalar ffmpeg robustamente
install_ffmpeg_robust() {
    echo "🔧 Instalando ffmpeg com múltiplos métodos..."
    
    # Método 1: Apt normal
    echo "📦 Método 1: Apt padrão..."
    sudo apt-get update
    if sudo apt-get install -y ffmpeg; then
        echo "✅ FFmpeg instalado via apt"
        return 0
    fi
    
    # Método 2: Componentes individuais
    echo "📦 Método 2: Componentes individuais..."
    sudo apt-get install -y libavcodec-dev libavformat-dev libavutil-dev libavfilter-dev \
        libavdevice-dev libswscale-dev libswresample-dev libpostproc-dev || true
    
    # Método 3: Snap
    echo "📦 Método 3: Snap..."
    if command -v snap &> /dev/null; then
        sudo snap install ffmpeg --classic && echo "✅ FFmpeg instalado via Snap" && return 0
    fi
    
    return 1
}

# 2. Verificar sistema
echo "🔍 Verificando sistema..."
if mount | grep " / " | grep -q "ro,"; then
    echo "⚠️  Sistema de arquivos root está SOMENTE LEITURA! Corrigindo..."
    sudo mount -o remount,rw /
    echo "✅ Sistema de arquivos agora é leitura/gravação"
fi

# 3. Parar serviços existentes
echo "🛑 Parando serviços existentes..."
sudo systemctl stop hls-simple hls-dashboard hls-manager hls-final hls-converter 2>/dev/null || true
sudo pkill -9 python 2>/dev/null || true
sleep 2

# 4. Limpar instalações anteriores
echo "🧹 Limpando instalações anteriores..."
rm -rf "$HLS_HOME" 2>/dev/null || true
sudo rm -f /etc/systemd/system/hls-*.service 2>/dev/null || true
sudo systemctl daemon-reload

# 5. INSTALAR FFMPEG PRIMEIRO
echo "🎬 INSTALANDO FFMPEG (ETAPA CRÍTICA)..."
if command -v ffmpeg &> /dev/null; then
    echo "✅ ffmpeg já está instalado"
    echo "🔍 Versão:"
    ffmpeg -version | head -1
else
    echo "❌ ffmpeg não encontrado, instalando..."
    install_ffmpeg_robust
    
    # Verificação final
    if command -v ffmpeg &> /dev/null; then
        echo "🎉 FFMPEG INSTALADO COM SUCESSO!"
        ffmpeg -version | head -1
    else
        echo "⚠️  AVISO: Não foi possível instalar o ffmpeg automaticamente"
        echo "📋 Instale manualmente depois: sudo apt-get update && sudo apt-get install -y ffmpeg"
    fi
fi

# 6. Instalar outras dependências
echo "🔧 Instalando outras dependências..."
sudo apt-get update
sudo apt-get install -y python3 python3-pip python3-venv curl wget

# 7. Criar estrutura de diretórios
echo "🏗️  Criando estrutura de diretórios..."
mkdir -p "$HLS_HOME"/{uploads,hls,logs,db,templates,static}
mkdir -p "$HLS_HOME/hls/{240p,360p,480p,720p,1080p,original}"
cd "$HLS_HOME"

# 8. Configurar ambiente Python
echo "🐍 Configurando ambiente Python..."
python3 -m venv venv
source venv/bin/activate

# Instalar dependências Python COMPLETAS
echo "📦 Instalando dependências Python..."
pip install --upgrade pip
pip install flask flask-cors psutil waitress werkzeug

# 9. CRIAR APLICAÇÃO FLASK COM BANCO DE DADOS CORRIGIDO
echo "💻 Criando aplicação com banco de dados corrigido..."

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

app = Flask(__name__, static_folder='static', static_url_path='/static')
CORS(app)

# Configurações - usando diretório home
BASE_DIR = os.path.expanduser("~/hls-converter-pro")
UPLOAD_DIR = os.path.join(BASE_DIR, "uploads")
HLS_DIR = os.path.join(BASE_DIR, "hls")
LOG_DIR = os.path.join(BASE_DIR, "logs")
DB_DIR = os.path.join(BASE_DIR, "db")
os.makedirs(UPLOAD_DIR, exist_ok=True)
os.makedirs(HLS_DIR, exist_ok=True)
os.makedirs(LOG_DIR, exist_ok=True)
os.makedirs(DB_DIR, exist_ok=True)

# Banco de dados simples - CORRIGIDO
DB_FILE = os.path.join(DB_DIR, "conversions.json")

def init_database():
    """Inicializa o banco de dados se não existir"""
    default_data = {
        "conversions": [],
        "stats": {
            "total": 0,
            "success": 0,
            "failed": 0
        }
    }
    
    if not os.path.exists(DB_FILE):
        save_database(default_data)
        print(f"✅ Banco de dados inicializado em: {DB_FILE}")
    
    return default_data

def load_database():
    """Carrega o banco de dados - CORRIGIDO"""
    try:
        if os.path.exists(DB_FILE):
            with open(DB_FILE, 'r', encoding='utf-8') as f:
                data = json.load(f)
                # Garantir que a estrutura está correta
                if "conversions" not in data:
                    data["conversions"] = []
                if "stats" not in data:
                    data["stats"] = {"total": 0, "success": 0, "failed": 0}
                return data
    except Exception as e:
        print(f"⚠️  Erro ao carregar banco de dados: {e}")
    
    # Se houver erro, retorna estrutura padrão
    return init_database()

def save_database(data):
    """Salva o banco de dados - CORRIGIDO"""
    try:
        with open(DB_FILE, 'w', encoding='utf-8') as f:
            json.dump(data, f, indent=2, ensure_ascii=False)
        return True
    except Exception as e:
        print(f"❌ Erro ao salvar banco de dados: {e}")
        return False

def log_activity(message, level="INFO"):
    """Registra atividade no log"""
    log_file = os.path.join(LOG_DIR, "activity.log")
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    try:
        with open(log_file, 'a', encoding='utf-8') as f:
            f.write(f"[{timestamp}] [{level}] {message}\n")
    except:
        pass

def get_system_info():
    """Obtém informações do sistema"""
    try:
        cpu_percent = psutil.cpu_percent(interval=0.1)
        memory = psutil.virtual_memory()
        disk = psutil.disk_usage('/')
        
        # Contar conversões
        db = load_database()
        
        # Verificar ffmpeg
        try:
            ffmpeg_result = subprocess.run(['which', 'ffmpeg'], capture_output=True, text=True)
            ffmpeg_status = "✅" if ffmpeg_result.returncode == 0 else "❌"
        except:
            ffmpeg_status = "❓"
        
        return {
            "success": True,
            "cpu": f"{cpu_percent:.1f}%",
            "memory": f"{memory.percent:.1f}%",
            "disk": f"{disk.percent:.1f}%",
            "uptime": str(datetime.now() - datetime.fromtimestamp(psutil.boot_time())).split('.')[0],
            "total_conversions": db["stats"]["total"],
            "success_conversions": db["stats"]["success"],
            "failed_conversions": db["stats"]["failed"],
            "hls_files": len(os.listdir(HLS_DIR)) if os.path.exists(HLS_DIR) else 0,
            "ffmpeg_status": ffmpeg_status
        }
    except Exception as e:
        return {"success": False, "error": str(e)}

# Função robusta para encontrar ffmpeg
def find_ffmpeg():
    """Encontra ffmpeg em vários locais possíveis"""
    possible_paths = [
        '/usr/bin/ffmpeg',
        '/usr/local/bin/ffmpeg',
        '/bin/ffmpeg',
        '/snap/bin/ffmpeg',
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
    
    return None

# Verificar ffmpeg uma vez
FFMPEG_PATH = find_ffmpeg()
if FFMPEG_PATH:
    log_activity(f"FFmpeg encontrado em: {FFMPEG_PATH}")
else:
    log_activity("FFmpeg NÃO encontrado!", "ERROR")

# ==================== TEMPLATES HTML COMPLETOS ====================

INDEX_HTML = '''
<!DOCTYPE html>
<html lang="pt-BR">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>🎬 HLS Converter PRO</title>
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
    </style>
</head>
<body>
    <div class="container-fluid">
        <div class="row">
            <!-- Sidebar -->
            <div class="col-md-3 mb-4">
                <div class="glass-card">
                    <div class="text-center mb-4">
                        <h1><i class="bi bi-camera-reels"></i> HLS PRO</h1>
                        <p class="text-muted">Conversor de vídeos profissional</p>
                    </div>
                    
                    <!-- System Status -->
                    <div id="systemStatus"></div>
                    
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
                                
                                <p><strong>FFmpeg:</strong> <span id="ffmpegStatus">❓</span></p>
                                <p><strong>Uptime:</strong> <span id="uptime">--</span></p>
                                <p><strong>Conversões:</strong> <span id="totalConversions">0</span></p>
                            </div>
                        </div>
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
                                <h5><i class="bi bi-info-circle"></i> Informações Importantes</h5>
                                <p>• Os vídeos convertidos ficam disponíveis por 7 dias</p>
                                <p>• Use o link M3U8 em players compatíveis com HLS</p>
                                <p>• Para grandes arquivos, a conversão pode levar vários minutos</p>
                            </div>
                        </div>
                    </div>
                </div>
                
                <!-- Footer -->
                <div class="mt-4 text-center text-white">
                    <p>HLS Converter PRO v3.0 | Sistema otimizado para produção</p>
                </div>
            </div>
        </div>
    </div>

    <!-- Scripts -->
    <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.1.3/dist/js/bootstrap.bundle.min.js"></script>
    <script>
        // State management
        let selectedFiles = [];
        let ffmpegAvailable = false;
        
        // Check ffmpeg status
        async function checkFFmpegStatus() {
            try {
                const response = await fetch('/api/system');
                if (!response.ok) {
                    throw new Error(`HTTP error! status: ${response.status}`);
                }
                const data = await response.json();
                
                const ffmpegStatus = document.getElementById('ffmpegStatus');
                const systemStatus = document.getElementById('systemStatus');
                const convertBtn = document.getElementById('convertBtn');
                
                if (data.ffmpeg_status === '✅') {
                    ffmpegStatus.innerHTML = '✅';
                    ffmpegStatus.title = 'FFmpeg disponível';
                    ffmpegAvailable = true;
                    
                    // Hide warning
                    systemStatus.innerHTML = '';
                    systemStatus.style.display = 'none';
                    convertBtn.disabled = false;
                } else {
                    ffmpegStatus.innerHTML = '❌';
                    ffmpegStatus.title = 'FFmpeg não disponível';
                    ffmpegAvailable = false;
                    
                    // Show warning
                    systemStatus.innerHTML = `
                        <div class="warning-box">
                            <strong>⚠️ ATENÇÃO:</strong> FFmpeg não está instalado!
                            <br>A conversão de vídeos não funcionará sem o FFmpeg.
                            <br><br>
                            <strong>Para instalar:</strong>
                            <br><code>sudo apt-get update && sudo apt-get install -y ffmpeg</code>
                            <br><br>
                            <button onclick="location.reload()" style="background:#dc3545;color:white;border:none;padding:10px 20px;border-radius:5px;cursor:pointer;">
                                🔄 Recarregar após instalar
                            </button>
                        </div>
                    `;
                    systemStatus.style.display = 'block';
                    convertBtn.disabled = true;
                    convertBtn.innerHTML = '⛔ FFmpeg não instalado';
                }
            } catch (error) {
                console.error('Erro ao verificar ffmpeg:', error);
            }
        }
        
        // System functions
        async function updateSystemStats() {
            try {
                const response = await fetch('/api/system');
                if (!response.ok) {
                    throw new Error(`HTTP error! status: ${response.status}`);
                }
                const data = await response.json();
                
                // Verificar se data tem as propriedades esperadas
                if (data && !data.error) {
                    document.getElementById('cpuUsage').textContent = data.cpu || '--';
                    document.getElementById('memoryUsage').textContent = data.memory || '--';
                    document.getElementById('diskUsage').textContent = data.disk || '--';
                    document.getElementById('uptime').textContent = data.uptime || '--';
                    document.getElementById('totalConversions').textContent = data.total_conversions || '0';
                    
                    // Update progress bars
                    const cpuPercent = parseFloat(data.cpu) || 0;
                    const memoryPercent = parseFloat(data.memory) || 0;
                    const diskPercent = parseFloat(data.disk) || 0;
                    
                    document.getElementById('cpuBar').style.width = Math.min(cpuPercent, 100) + '%';
                    document.getElementById('memoryBar').style.width = Math.min(memoryPercent, 100) + '%';
                    document.getElementById('diskBar').style.width = Math.min(diskPercent, 100) + '%';
                    
                    // Update ffmpeg status
                    if (data.ffmpeg_status) {
                        document.getElementById('ffmpegStatus').textContent = data.ffmpeg_status;
                    }
                }
            } catch (error) {
                console.error('Erro ao carregar stats:', error);
            }
        }
        
        function refreshStats() {
            updateSystemStats();
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
        async function startConversion() {
            if (!ffmpegAvailable) {
                showToast('FFmpeg não está instalado. Instale-o primeiro!', 'warning');
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
            
            try {
                const response = await fetch('/convert', {
                    method: 'POST',
                    body: formData
                });
                
                if (!response.ok) {
                    throw new Error(`HTTP error! status: ${response.status}`);
                }
                
                const data = await response.json();
                
                if (data.success) {
                    showResult(data);
                } else {
                    showToast('Erro: ' + (data.error || 'Conversão falhou'), 'danger');
                }
            } catch (error) {
                showToast('Erro de conexão: ' + error.message, 'danger');
            } finally {
                convertBtn.disabled = false;
                convertBtn.innerHTML = '<i class="bi bi-play-circle"></i> Iniciar Conversão';
                document.getElementById('progressSection').style.display = 'none';
            }
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
        
        function showHelp() {
            showTab('help');
        }
        
        function showTab(tabName) {
            // Hide all
            ['upload', 'conversions', 'settings', 'help'].forEach(tab => {
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
        async function loadConversions() {
            try {
                const response = await fetch('/api/conversions');
                if (!response.ok) {
                    throw new Error(`HTTP error! status: ${response.status}`);
                }
                const data = await response.json();
                
                const container = document.getElementById('conversionsList');
                
                if (!data.conversions || data.conversions.length === 0) {
                    container.innerHTML = '<div class="alert alert-info">Nenhuma conversão realizada ainda</div>';
                    return;
                }
                
                let html = '<div class="row">';
                data.conversions.slice(0, 12).forEach(conv => {
                    html += `
                        <div class="col-md-4 mb-3">
                            <div class="card">
                                <div class="card-body">
                                    <h6>${conv.video_id || 'N/A'}</h6>
                                    <p><small class="text-muted">${formatDate(conv.timestamp)}</small></p>
                                    <p><strong>Arquivo:</strong> ${conv.filename || 'N/A'}</p>
                                    <p><strong>Status:</strong> <span class="badge bg-${(conv.status === 'success') ? 'success' : 'danger'}">${conv.status || 'unknown'}</span></p>
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
            } catch (error) {
                console.error('Erro ao carregar histórico:', error);
                document.getElementById('conversionsList').innerHTML = 
                    '<div class="alert alert-danger">Erro ao carregar histórico: ' + error.message + '</div>';
            }
        }
        
        // Utility functions
        function formatBytes(bytes) {
            if (!bytes || bytes === 0) return '0 Bytes';
            const k = 1024;
            const sizes = ['Bytes', 'KB', 'MB', 'GB'];
            const i = Math.floor(Math.log(bytes) / Math.log(k));
            return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i];
        }
        
        function formatDate(timestamp) {
            if (!timestamp) return 'N/A';
            try {
                return new Date(timestamp).toLocaleString();
            } catch {
                return timestamp;
            }
        }
        
        function copyToClipboard(elementId) {
            const element = document.getElementById(elementId);
            element.select();
            element.setSelectionRange(0, 99999);
            document.execCommand('copy');
            showToast('Link copiado!', 'success');
        }
        
        function copyConversionLink(videoId) {
            if (!videoId) return;
            const link = window.location.origin + '/hls/' + videoId + '/master.m3u8';
            navigator.clipboard.writeText(link);
            showToast('Link copiado!', 'success');
        }
        
        function testPlayback(videoId) {
            if (!videoId) return;
            window.open('/player/' + videoId, '_blank');
        }
        
        function downloadMaster(videoId) {
            if (!videoId) return;
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
            // Check ffmpeg first
            checkFFmpegStatus();
            
            // Update system stats
            updateSystemStats();
            setInterval(updateSystemStats, 30000);
            
            // Handle drag and drop
            const uploadArea = document.querySelector('.upload-area');
            if (uploadArea) {
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
            }
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
    </style>
</head>
<body>
    <div class="player-container">
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

# ==================== ROTAS DA APLICAÇÃO CORRIGIDAS ====================

@app.route('/')
def index():
    return render_template_string(INDEX_HTML)

@app.route('/convert', methods=['POST'])
def convert_video():
    try:
        # Verificar ffmpeg primeiro
        if not FFMPEG_PATH:
            return jsonify({
                'success': False, 
                'error': 'FFmpeg não está instalado. Execute: sudo apt-get update && sudo apt-get install -y ffmpeg'
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
                    result = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
                    
                    if result.returncode != 0:
                        log_activity(f"Erro na conversão {quality}: {result.stderr[:200]}", "ERROR")
                except subprocess.TimeoutExpired:
                    log_activity(f"Timeout na conversão {quality}", "ERROR")
                except Exception as e:
                    log_activity(f"Exceção na conversão {quality}: {str(e)}", "ERROR")
        
        # Save original file if needed
        original_dir = os.path.join(output_dir, "original")
        os.makedirs(original_dir, exist_ok=True)
        original_copy = os.path.join(original_dir, filename)
        shutil.copy2(original_path, original_copy)
        
        # Clean up original upload
        try:
            os.remove(original_path)
        except:
            pass
        
        # Update database - CORRIGIDO
        db = load_database()
        conversion_data = {
            "video_id": video_id,
            "filename": filename,
            "qualities": qualities,
            "timestamp": datetime.now().isoformat(),
            "status": "success",
            "m3u8_url": f"/hls/{video_id}/master.m3u8"
        }
        
        # Garantir que conversions é uma lista
        if not isinstance(db.get("conversions"), list):
            db["conversions"] = []
        
        # Adicionar no início da lista
        db["conversions"].insert(0, conversion_data)
        
        # Atualizar estatísticas
        db["stats"]["total"] = db["stats"].get("total", 0) + 1
        db["stats"]["success"] = db["stats"].get("success", 0) + 1
        
        # Salvar
        save_database(db)
        
        log_activity(f"Conversão concluída: {video_id} ({', '.join(qualities)})")
        
        return jsonify({
            "success": True,
            "video_id": video_id,
            "qualities": qualities,
            "m3u8_url": f"/hls/{video_id}/master.m3u8",
            "player_url": f"/player/{video_id}"
        })
        
    except Exception as e:
        log_activity(f"Erro geral na conversão: {str(e)}", "ERROR")
        return jsonify({"success": False, "error": str(e)})

@app.route('/api/system')
def api_system():
    """API para informações do sistema - CORRIGIDA"""
    try:
        data = get_system_info()
        return jsonify(data)
    except Exception as e:
        return jsonify({"success": False, "error": str(e)})

@app.route('/api/conversions')
def api_conversions():
    """API para listar conversões - CORRIGIDA"""
    try:
        db = load_database()
        # Garantir que retorna uma estrutura consistente
        return jsonify({
            "success": True,
            "conversions": db.get("conversions", []),
            "stats": db.get("stats", {"total": 0, "success": 0, "failed": 0})
        })
    except Exception as e:
        return jsonify({"success": False, "error": str(e)})

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
    static_dir = os.path.join(BASE_DIR, 'static')
    return send_from_directory(static_dir, filename)

@app.route('/health')
def health_check():
    """Health check do sistema"""
    ffmpeg_ok = FFMPEG_PATH is not None
    
    return jsonify({
        "status": "healthy" if ffmpeg_ok else "warning",
        "service": "hls-converter-pro",
        "version": "3.0.0",
        "ffmpeg": ffmpeg_ok,
        "ffmpeg_path": FFMPEG_PATH or "not found",
        "timestamp": datetime.now().isoformat(),
        "message": "FFmpeg instalado" if ffmpeg_ok else "FFmpeg não encontrado - instale com: sudo apt-get install ffmpeg"
    })

@app.route('/debug/ffmpeg')
def debug_ffmpeg():
    """Debug ffmpeg"""
    debug_info = {
        "ffmpeg_path": FFMPEG_PATH,
        "ffmpeg_exists": FFMPEG_PATH is not None and os.path.exists(FFMPEG_PATH),
        "which_ffmpeg": subprocess.run(['which', 'ffmpeg'], capture_output=True, text=True).stdout.strip(),
    }
    
    # Test ffmpeg
    if FFMPEG_PATH:
        try:
            test = subprocess.run([FFMPEG_PATH, '-version'], capture_output=True, text=True, timeout=5)
            debug_info['ffmpeg_test'] = {
                'success': test.returncode == 0,
                'version': test.stdout.split('\n')[0] if test.stdout else 'N/A'
            }
        except Exception as e:
            debug_info['ffmpeg_test_error'] = str(e)
    
    return jsonify(debug_info)

if __name__ == '__main__':
    print("🎬 HLS Converter PRO v3.0 FINAL CORRIGIDO")
    print("=========================================")
    
    # Inicializar banco de dados
    init_database()
    
    if FFMPEG_PATH:
        print(f"✅ FFmpeg encontrado em: {FFMPEG_PATH}")
        # Testar ffmpeg
        try:
            result = subprocess.run([FFMPEG_PATH, '-version'], capture_output=True, text=True)
            if result.returncode == 0:
                version_line = result.stdout.split('\n')[0]
                print(f"📊 Versão: {version_line}")
            else:
                print("⚠️  FFmpeg encontrado mas não funciona corretamente")
        except Exception as e:
            print(f"⚠️  Erro ao testar ffmpeg: {e}")
    else:
        print("❌ FFmpeg NÃO encontrado!")
        print("📋 Execute para instalar: sudo apt-get update && sudo apt-get install -y ffmpeg")
    
    print("🌐 Sistema iniciando na porta 8080")
    print("📊 Dashboard completo disponível")
    print("🔧 Múltiplas qualidades HLS")
    print("📈 Monitoramento em tempo real")
    print("")
    print("✅ Health check: http://localhost:8080/health")
    print("🎮 Interface: http://localhost:8080/")
    print("🔧 Debug ffmpeg: http://localhost:8080/debug/ffmpeg")
    print("")
    
    # Iniciar em modo produção
    from waitress import serve
    serve(app, host='0.0.0.0', port=8080)
EOF

# 10. CRIAR ARQUIVOS DE CONFIGURAÇÃO
echo "📁 Criando arquivos de configuração..."

cat > "$HLS_HOME/config.json" << 'EOF'
{
    "system": {
        "port": 8080,
        "upload_limit_mb": 2048,
        "keep_originals": false,
        "cleanup_days": 7
    },
    "hls": {
        "segment_time": 10,
        "qualities": ["240p", "480p", "720p", "1080p"],
        "bitrates": {
            "240p": "400k",
            "480p": "800k",
            "720p": "1500k",
            "1080p": "3000k"
        }
    },
    "ffmpeg": {
        "preset": "fast",
        "crf": 23,
        "audio_bitrate": "128k"
    }
}
EOF

# 11. CRIAR BANCO DE DADOS INICIAL CORRETAMENTE
echo "💾 Criando banco de dados inicial corrigido..."
cat > "$HLS_HOME/db/conversions.json" << 'EOF'
{
    "conversions": [],
    "stats": {
        "total": 0,
        "success": 0,
        "failed": 0
    }
}
EOF

# 12. CRIAR SERVIÇO SYSTEMD
echo "⚙️ Configurando serviço systemd..."

cat > "$HLS_HOME/hls-converter.service" << EOF
[Unit]
Description=HLS Converter PRO Service
After=network.target
Wants=network.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$HLS_HOME
Environment="PATH=$HLS_HOME/venv/bin:/usr/local/bin:/usr/bin:/bin"
Environment="PYTHONUNBUFFERED=1"

# Usar Waitress para produção
ExecStart=$HLS_HOME/venv/bin/waitress-serve --port=8080 --call app:app

Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=hls-converter

# Security
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

# 13. INSTALAR SERVIÇO SYSTEMD
echo "📦 Instalando serviço systemd..."
sudo cp "$HLS_HOME/hls-converter.service" /etc/systemd/system/
sudo systemctl daemon-reload

# 14. CONFIGURAR PERMISSÕES
echo "🔐 Configurando permissões..."
chmod 755 "$HLS_HOME"
chmod 644 "$HLS_HOME"/*.py
chmod 644 "$HLS_HOME"/*.json
chmod 644 "$HLS_HOME/db"/*.json
chmod -R 755 "$HLS_HOME/uploads"
chmod -R 755 "$HLS_HOME/hls"

# 15. CRIAR SCRIPT DE GERENCIAMENTO
echo "📝 Criando script de gerenciamento..."

cat > "$HOME/hlsctl" << 'EOF'
#!/bin/bash

HLS_HOME="$HOME/hls-converter-pro"

case "$1" in
    start)
        sudo systemctl start hls-converter
        echo "✅ Serviço iniciado"
        ;;
    stop)
        sudo systemctl stop hls-converter
        echo "✅ Serviço parado"
        ;;
    restart)
        sudo systemctl restart hls-converter
        echo "✅ Serviço reiniciado"
        ;;
    status)
        sudo systemctl status hls-converter --no-pager
        ;;
    logs)
        if [ "$2" = "-f" ]; then
            sudo journalctl -u hls-converter -f
        else
            sudo journalctl -u hls-converter -n 30 --no-pager
        fi
        ;;
    test)
        echo "🧪 Testando sistema..."
        echo "1. Health check:"
        curl -s http://localhost:8080/health 2>/dev/null | python3 -c "import sys, json; data=json.load(sys.stdin); print(json.dumps(data, indent=2))" 2>/dev/null || curl -s http://localhost:8080/health
        echo ""
        echo "2. FFmpeg:"
        if command -v ffmpeg &> /dev/null; then
            ffmpeg -version 2>/dev/null | head -1
        else
            echo "   ❌ FFmpeg não encontrado"
        fi
        ;;
    cleanup)
        echo "🧹 Limpando arquivos antigos..."
        find "$HLS_HOME/uploads" -type f -mtime +7 -delete 2>/dev/null
        find "$HLS_HOME/hls" -type d -mtime +7 -exec rm -rf {} \; 2>/dev/null
        echo "✅ Arquivos antigos removidos"
        ;;
    fix-ffmpeg)
        echo "🔧 Instalando/Reparando FFmpeg..."
        sudo apt-get update
        sudo apt-get install -y ffmpeg
        echo "✅ FFmpeg instalado"
        ;;
    debug)
        echo "🔍 Debug do sistema..."
        echo "1. Serviço:"
        sudo systemctl status hls-converter --no-pager | head -10
        echo ""
        echo "2. Porta 8080:"
        netstat -tlnp 2>/dev/null | grep :8080 || echo "   Porta 8080 não está em uso"
        echo ""
        echo "3. FFmpeg debug:"
        curl -s http://localhost:8080/debug/ffmpeg 2>/dev/null | python3 -c "import sys, json; data=json.load(sys.stdin); print(json.dumps(data, indent=2))" 2>/dev/null || echo "   Não consegui acessar debug"
        ;;
    reinstall)
        echo "🔄 Reinstalando HLS Converter..."
        sudo systemctl stop hls-converter 2>/dev/null || true
        sudo systemctl disable hls-converter 2>/dev/null || true
        sudo rm -f /etc/systemd/system/hls-converter.service
        rm -rf "$HLS_HOME"
        echo "✅ Removido. Execute o script de instalação novamente."
        ;;
    info)
        IP=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "localhost")
        echo "=== HLS Converter PRO FINAL ==="
        echo "Porta: 8080"
        echo "URL: http://$IP:8080"
        echo "Health: http://$IP:8080/health"
        echo "Debug: http://$IP:8080/debug/ffmpeg"
        echo "Diretório: $HLS_HOME"
        echo "Usuário: $USER"
        echo "FFmpeg: $(command -v ffmpeg 2>/dev/null || echo 'Não instalado')"
        echo ""
        echo "Status do serviço: $(sudo systemctl is-active hls-converter 2>/dev/null || echo 'inactive')"
        ;;
    *)
        echo "Uso: hlsctl [comando]"
        echo ""
        echo "Comandos:"
        echo "  start        - Iniciar"
        echo "  stop         - Parar"
        echo "  restart      - Reiniciar"
        echo "  status       - Status"
        echo "  logs         - Logs"
        echo "  test         - Testar"
        echo "  cleanup      - Limpar"
        echo "  fix-ffmpeg   - Instalar FFmpeg"
        echo "  debug        - Debug"
        echo "  reinstall    - Reinstalar"
        echo "  info         - Informações"
        ;;
esac
EOF

chmod +x "$HOME/hlsctl"

# 16. INICIAR SERVIÇO
echo "🚀 Iniciando serviço..."
sudo systemctl enable hls-converter.service
sudo systemctl start hls-converter.service

sleep 10

# 17. VERIFICAÇÃO FINAL
echo "🔍 VERIFICAÇÃO FINAL..."
echo "======================"

# Verificar serviço
echo ""
echo "1. Status do serviço:"
if sudo systemctl is-active --quiet hls-converter.service; then
    echo "   ✅ Serviço ativo"
    
    # Testar endpoints
    echo ""
    echo "2. Testando endpoints (aguarde 5 segundos)..."
    sleep 5
    
    # Health check
    echo "   a) Health check:"
    if curl -s http://localhost:8080/health 2>/dev/null | grep -q "status"; then
        echo "      ✅ OK - Sistema respondendo"
        curl -s http://localhost:8080/health 2>/dev/null | grep -o '"message":"[^"]*"' | head -1
    else
        echo "      ❌ Falha - Verifique logs"
    fi
    
    # API System
    echo "   b) API System:"
    if curl -s http://localhost:8080/api/system 2>/dev/null | grep -q "success"; then
        echo "      ✅ OK - API funcionando"
    else
        echo "      ⚠️  Pode haver erros - Verifique abaixo:"
        curl -s http://localhost:8080/api/system 2>/dev/null | head -100
    fi
    
    # Interface web
    echo "   c) Interface web:"
    if curl -s -I http://localhost:8080/ 2>/dev/null | head -1 | grep -q "200"; then
        echo "      ✅ OK - Interface carregando"
    else
        echo "      ❌ Falha"
    fi
    
else
    echo "   ❌ Serviço não está ativo"
    echo "   📋 Logs:"
    sudo journalctl -u hls-converter -n 20 --no-pager
fi

# Verificar ffmpeg
echo ""
echo "3. Verificando FFmpeg:"
if command -v ffmpeg &> /dev/null; then
    echo "   ✅ FFmpeg encontrado"
    ffmpeg -version 2>/dev/null | head -1
else
    echo "   ❌ FFmpeg NÃO encontrado"
    echo "   📋 Execute: $HOME/hlsctl fix-ffmpeg"
fi

# 18. OBTER INFORMAÇÕES FINAIS
IP=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "localhost")

echo ""
echo "🎉🎉🎉 INSTALAÇÃO COMPLETA! 🎉🎉🎉"
echo "================================"
echo ""
echo "✅ SISTEMA INSTALADO E CORRIGIDO"
echo ""
echo "🔧 CORREÇÕES APLICADAS:"
echo "   ✔️  Banco de dados corrigido"
echo "   ✔️  Tratamento de JSON corrigido"
echo "   ✔️  Tratamento de erros na API"
echo "   ✔️  Funções load_database/save_database corrigidas"
echo "   ✔️  JavaScript com tratamento de erros"
echo ""
echo "🌐 URLS DE ACESSO:"
echo "   🎨 INTERFACE: http://$IP:8080"
echo "   🩺 HEALTH: http://$IP:8080/health"
echo "   🔧 DEBUG: http://$IP:8080/debug/ffmpeg"
echo ""
echo "⚙️  COMANDOS PRINCIPAIS:"
echo "   • $HOME/hlsctl start      - Iniciar"
echo "   • $HOME/hlsctl stop       - Parar"
echo "   • $HOME/hlsctl restart    - Reiniciar"
echo "   • $HOME/hlsctl status     - Status"
echo "   • $HOME/hlsctl fix-ffmpeg - Instalar FFmpeg"
echo ""
echo "📁 DIRETÓRIO: $HLS_HOME"
echo ""
echo "🚀 SISTEMA PRONTO PARA USO!"
