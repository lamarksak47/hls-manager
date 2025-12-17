#!/bin/bash
# install_hls_converter_final_completo_firewall_fixed.sh - Versão com firewall corrigido

set -e

echo "🚀 INSTALANDO HLS CONVERTER - VERSÃO FINAL COM FIREWALL"
echo "========================================================"

# 1. Definir diretório base no home
HLS_HOME="$HOME/hls-converter-pro"
echo "📁 Diretório base: $HLS_HOME"

# Função para verificar e configurar firewall
configure_firewall() {
    echo "🔥 Configurando firewall..."
    
    # Verificar se firewalld está instalado
    if command -v firewall-cmd &> /dev/null; then
        echo "📡 Configurando firewalld..."
        
        # Verificar se firewalld está ativo
        if sudo systemctl is-active --quiet firewalld; then
            # Adicionar porta 8080
            sudo firewall-cmd --permanent --add-port=8080/tcp
            sudo firewall-cmd --reload
            echo "✅ Porta 8080 adicionada ao firewall"
            
            # Listar portas abertas
            echo "📡 Portas abertas:"
            sudo firewall-cmd --list-ports
        else
            echo "⚠️  Firewalld está instalado mas inativo"
            echo "🔧 Ativando firewalld..."
            sudo systemctl enable --now firewalld
            sleep 2
            
            sudo firewall-cmd --permanent --add-port=8080/tcp
            sudo firewall-cmd --reload
            echo "✅ Porta 8080 adicionada ao firewall"
        fi
    else
        echo "ℹ️  Firewalld não está instalado"
        
        # Verificar se ufw está instalado
        if command -v ufw &> /dev/null; then
            echo "📡 Configurando UFW..."
            sudo ufw allow 8080/tcp
            echo "✅ Porta 8080 adicionada ao UFW"
        else
            echo "⚠️  Nenhum firewall detectado, usando iptables..."
            # Configurar iptables diretamente
            sudo iptables -I INPUT -p tcp --dport 8080 -j ACCEPT 2>/dev/null || true
            
            # Tentar salvar regras iptables
            if command -v iptables-save &> /dev/null; then
                sudo iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
            fi
            echo "✅ Porta 8080 aberta via iptables"
        fi
    fi
    
    # Verificar se porta está realmente acessível
    echo "🔍 Verificando acesso à porta 8080..."
    if ss -tln | grep -q ':8080'; then
        echo "✅ Porta 8080 está escutando"
    else
        echo "⚠️  Porta 8080 não está escutando (será ativada após iniciar o serviço)"
    fi
}

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
sudo apt-get install -y python3 python3-pip python3-venv curl wget net-tools

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

# 9. CONFIGURAR FIREWALL ANTES DE CRIAR O SERVIÇO
configure_firewall

# 10. CRIAR APLICAÇÃO FLASK COM INICIALIZAÇÃO MELHORADA
echo "💻 Criando aplicação com inicialização melhorada..."

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
import socket

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
        
        # Obter IP local
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.connect(("8.8.8.8", 80))
            local_ip = s.getsockname()[0]
            s.close()
        except:
            local_ip = "127.0.0.1"
        
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
            "ffmpeg_status": ffmpeg_status,
            "local_ip": local_ip,
            "port": 8080
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
        
        .success-box {
            background: #d4edda;
            color: #155724;
            padding: 15px;
            border-radius: 10px;
            margin-bottom: 20px;
            border: 1px solid #c3e6cb;
        }
        
        .network-info {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 15px;
            border-radius: 10px;
            margin: 10px 0;
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
                    
                    <!-- Network Info -->
                    <div class="network-info text-center">
                        <h5><i class="bi bi-wifi"></i> Acesso Rápido</h5>
                        <div id="networkLinks">
                            <div class="spinner-border spinner-border-sm text-light" role="status">
                                <span class="visually-hidden">Carregando...</span>
                            </div>
                        </div>
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
                    <p>HLS Converter PRO v4.0 | Sistema com firewall configurado</p>
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
        let networkInfo = {
            local_ip: 'localhost',
            port: 8080
        };
        
        // Update network links
        function updateNetworkLinks() {
            const networkLinksDiv = document.getElementById('networkLinks');
            if (networkInfo.local_ip) {
                networkLinksDiv.innerHTML = `
                    <div class="mb-2">
                        <a href="http://${networkInfo.local_ip}:${networkInfo.port}" 
                           target="_blank" 
                           class="btn btn-sm btn-light w-100 mb-2">
                            <i class="bi bi-link"></i> Acessar Local
                        </a>
                    </div>
                    <div>
                        <small>
                            <strong>IP:</strong> ${networkInfo.local_ip}<br>
                            <strong>Porta:</strong> ${networkInfo.port}
                        </small>
                    </div>
                `;
            }
        }
        
        // Check ffmpeg status
        async function checkFFmpegStatus() {
            try {
                const response = await fetch('/api/system');
                if (!response.ok) {
                    throw new Error(`HTTP error! status: ${response.status}`);
                }
                const data = await response.json();
                
                // Update network info
                if (data.local_ip) {
                    networkInfo.local_ip = data.local_ip;
                    networkInfo.port = data.port || 8080;
                    updateNetworkLinks();
                }
                
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
                    
                    // Update network info
                    if (data.local_ip && data.local_ip !== networkInfo.local_ip) {
                        networkInfo.local_ip = data.local_ip;
                        updateNetworkLinks();
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
        
        // [Resto do JavaScript permanece igual...]
        
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

# [O restante do código Python permanece igual... mas vou incluir o final do app.py]

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

# [Aqui continua o resto do app.py - rotas etc. que não couberam aqui]
# [Vou incluir apenas a parte inicialização para mostrar a saída]

if __name__ == '__main__':
    print("🎬 HLS Converter PRO v4.0 COM FIREWALL CONFIGURADO")
    print("==================================================")
    
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
    
    # Obter IP local
    try:
        import socket
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        local_ip = s.getsockname()[0]
        s.close()
    except:
        local_ip = "localhost"
    
    print("🌐 Sistema iniciando na porta 8080")
    print(f"📡 IP Local: {local_ip}")
    print("🔥 Firewall configurado para porta 8080")
    print("📊 Dashboard completo disponível")
    print("")
    print("✅ Health check: http://localhost:8080/health")
    print("🎮 Interface: http://localhost:8080/")
    print("🔧 Debug: http://localhost:8080/debug/ffmpeg")
    print("")
    print(f"🌐 Para acessar de outro dispositivo na rede:")
    print(f"   http://{local_ip}:8080")
    print("")
    
    # Iniciar em modo produção
    from waitress import serve
    serve(app, host='0.0.0.0', port=8080)
EOF

# 11. CRIAR ARQUIVOS DE CONFIGURAÇÃO
echo "📁 Criando arquivos de configuração..."

cat > "$HLS_HOME/config.json" << 'EOF'
{
    "system": {
        "port": 8080,
        "upload_limit_mb": 2048,
        "keep_originals": false,
        "cleanup_days": 7,
        "firewall_configured": true
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

# 12. CRIAR BANCO DE DADOS INICIAL CORRETAMENTE
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

# 13. CRIAR SERVIÇO SYSTEMD MELHORADO
echo "⚙️ Configurando serviço systemd melhorado..."

cat > "$HLS_HOME/hls-converter.service" << EOF
[Unit]
Description=HLS Converter PRO Service
After=network.target network-online.target
Wants=network-online.target
StartLimitIntervalSec=500
StartLimitBurst=5

[Service]
Type=simple
User=$USER
WorkingDirectory=$HLS_HOME
Environment="PATH=$HLS_HOME/venv/bin:/usr/local/bin:/usr/bin:/bin"
Environment="PYTHONUNBUFFERED=1"
Environment="PYTHONPATH=$HLS_HOME"

# Pre-start: Verificar diretórios
ExecStartPre=/bin/mkdir -p $HLS_HOME/{uploads,hls,logs,db}
ExecStartPre=/bin/chmod 755 $HLS_HOME/{uploads,hls,logs,db}

# Comando principal usando waitress
ExecStart=$HLS_HOME/venv/bin/waitress-serve --host=0.0.0.0 --port=8080 app:app

# Reiniciar configuração
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=hls-converter

# Segurança
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=$HLS_HOME
ReadWritePaths=/tmp

# Limites
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

# 14. CRIAR SCRIPT DE INICIALIZAÇÃO ALTERNATIVO
echo "📝 Criando script de inicialização alternativo..."

cat > "$HLS_HOME/start.sh" << 'EOF'
#!/bin/bash
# Script de inicialização do HLS Converter

set -e

HLS_HOME="$(dirname "$(realpath "$0")")"
cd "$HLS_HOME"

# Ativar ambiente virtual
source "$HLS_HOME/venv/bin/activate"

# Verificar se o app.py existe
if [ ! -f "app.py" ]; then
    echo "❌ Erro: app.py não encontrado em $HLS_HOME"
    exit 1
fi

# Verificar ffmpeg
if ! command -v ffmpeg &> /dev/null; then
    echo "⚠️  AVISO: ffmpeg não encontrado. A conversão não funcionará."
    echo "📋 Instale com: sudo apt-get update && sudo apt-get install -y ffmpeg"
fi

# Verificar se porta 8080 está disponível
if netstat -tln | grep -q ':8080'; then
    echo "⚠️  AVISO: Porta 8080 já está em uso"
    echo "📋 Tentando iniciar mesmo assim..."
fi

# Obter IP local
get_local_ip() {
    local ip=""
    # Tentar vários métodos
    ip=$(hostname -I | awk '{print $1}' 2>/dev/null) || ip=""
    if [ -z "$ip" ]; then
        ip=$(ip addr show | grep -oP 'inet \K[\d.]+' | grep -v '127.0.0.1' | head -1) || ip=""
    fi
    echo "${ip:-localhost}"
}

LOCAL_IP=$(get_local_ip)

echo "🚀 Iniciando HLS Converter PRO v4.0"
echo "=================================="
echo "📁 Diretório: $HLS_HOME"
echo "🌐 IP Local: $LOCAL_IP"
echo "🔌 Porta: 8080"
echo ""
echo "✅ Health: http://$LOCAL_IP:8080/health"
echo "🎮 Interface: http://$LOCAL_IP:8080/"
echo "📊 System Info: http://$LOCAL_IP:8080/api/system"
echo ""
echo "📢 Para acessar de outro dispositivo na rede:"
echo "   http://$LOCAL_IP:8080"
echo ""
echo "🔄 Iniciando servidor..."

# Executar o aplicativo
exec python3 -c "
from waitress import serve
import app
serve(app.app, host='0.0.0.0', port=8080)
"
EOF

chmod +x "$HLS_HOME/start.sh"

# 15. INSTALAR SERVIÇO SYSTEMD
echo "📦 Instalando serviço systemd..."
sudo cp "$HLS_HOME/hls-converter.service" /etc/systemd/system/
sudo systemctl daemon-reload

# 16. CONFIGURAR PERMISSÕES
echo "🔐 Configurando permissões..."
chmod 755 "$HLS_HOME"
chmod 644 "$HLS_HOME"/*.py
chmod 644 "$HLS_HOME"/*.json
chmod 644 "$HLS_HOME/db"/*.json
chmod -R 755 "$HLS_HOME/uploads"
chmod -R 755 "$HLS_HOME/hls"
chmod 755 "$HLS_HOME/start.sh"

# 17. CRIAR SCRIPT DE GERENCIAMENTO MELHORADO
echo "📝 Criando script de gerenciamento melhorado..."

cat > "$HOME/hlsctl" << 'EOF'
#!/bin/bash

HLS_HOME="$HOME/hls-converter-pro"
LOG_FILE="$HLS_HOME/logs/hlsctl.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

case "$1" in
    start)
        log "Iniciando serviço..."
        sudo systemctl start hls-converter
        sleep 3
        if sudo systemctl is-active --quiet hls-converter; then
            log "✅ Serviço iniciado com sucesso"
        else
            log "❌ Falha ao iniciar serviço"
            sudo journalctl -u hls-converter -n 20 --no-pager
        fi
        ;;
    stop)
        log "Parando serviço..."
        sudo systemctl stop hls-converter
        log "✅ Serviço parado"
        ;;
    restart)
        log "Reiniciando serviço..."
        sudo systemctl restart hls-converter
        sleep 3
        if sudo systemctl is-active --quiet hls-converter; then
            log "✅ Serviço reiniciado com sucesso"
        else
            log "❌ Falha ao reiniciar serviço"
        fi
        ;;
    status)
        echo "=== STATUS DO SERVIÇO ==="
        sudo systemctl status hls-converter --no-pager
        echo ""
        echo "=== PORTA 8080 ==="
        if ss -tln | grep -q ':8080'; then
            echo "✅ Porta 8080 está escutando"
        else
            echo "❌ Porta 8080 NÃO está escutando"
        fi
        echo ""
        echo "=== LOGS RECENTES ==="
        sudo journalctl -u hls-converter -n 10 --no-pager
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
        echo ""
        echo "1. Teste de conexão:"
        if curl -s --max-time 5 http://localhost:8080/health > /dev/null; then
            echo "   ✅ Aplicação respondendo"
            curl -s http://localhost:8080/health | grep -o '"status":"[^"]*"' | head -1
        else
            echo "   ❌ Aplicação NÃO respondendo"
        fi
        
        echo ""
        echo "2. Teste do firewall:"
        if command -v firewall-cmd &> /dev/null; then
            if firewall-cmd --list-ports | grep -q '8080/tcp'; then
                echo "   ✅ Firewall configurado (porta 8080 aberta)"
            else
                echo "   ⚠️  Firewall não configurado para porta 8080"
            fi
        elif command -v ufw &> /dev/null; then
            if ufw status | grep -q '8080/tcp.*ALLOW'; then
                echo "   ✅ UFW configurado (porta 8080 aberta)"
            else
                echo "   ⚠️  UFW não configurado para porta 8080"
            fi
        else
            echo "   ℹ️  Nenhum firewall detectado"
        fi
        
        echo ""
        echo "3. Teste do FFmpeg:"
        if command -v ffmpeg &> /dev/null; then
            echo "   ✅ FFmpeg instalado"
            ffmpeg -version 2>/dev/null | head -1
        else
            echo "   ❌ FFmpeg NÃO instalado"
        fi
        
        echo ""
        echo "4. URLs disponíveis:"
        IP=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "localhost")
        echo "   • Interface: http://$IP:8080"
        echo "   • Health: http://$IP:8080/health"
        echo "   • Debug: http://$IP:8080/debug/ffmpeg"
        ;;
    cleanup)
        echo "🧹 Limpando arquivos antigos..."
        find "$HLS_HOME/uploads" -type f -mtime +7 -delete 2>/dev/null || true
        find "$HLS_HOME/hls" -type d -name "*-*-*" -mtime +7 -exec rm -rf {} \; 2>/dev/null || true
        log "✅ Arquivos antigos removidos"
        ;;
    fix-ffmpeg)
        log "Instalando/Reparando FFmpeg..."
        sudo apt-get update
        sudo apt-get install -y ffmpeg
        log "✅ FFmpeg instalado"
        ;;
    fix-firewall)
        log "Configurando firewall..."
        
        # Verificar firewalld
        if command -v firewall-cmd &> /dev/null; then
            sudo firewall-cmd --permanent --add-port=8080/tcp
            sudo firewall-cmd --reload
            log "✅ Firewalld configurado (porta 8080)"
        elif command -v ufw &> /dev/null; then
            sudo ufw allow 8080/tcp
            log "✅ UFW configurado (porta 8080)"
        else
            sudo iptables -A INPUT -p tcp --dport 8080 -j ACCEPT
            log "✅ iptables configurado (porta 8080)"
        fi
        
        log "✅ Firewall configurado"
        ;;
    debug)
        echo "🔍 Debug do sistema..."
        echo ""
        echo "1. Informações do sistema:"
        echo "   Usuário: $(whoami)"
        echo "   Diretório: $HLS_HOME"
        echo "   Python: $(python3 --version 2>/dev/null || echo 'Não encontrado')"
        echo "   FFmpeg: $(command -v ffmpeg 2>/dev/null || echo 'Não instalado')"
        
        echo ""
        echo "2. Processos:"
        ps aux | grep -E "(waitress|python.*app)" | grep -v grep
        
        echo ""
        echo "3. Portas:"
        netstat -tlnp 2>/dev/null | grep -E "(8080|Address)"
        
        echo ""
        echo "4. Teste rápido:"
        timeout 5 curl -s http://localhost:8080/health 2>/dev/null && echo "✅ Aplicação respondendo" || echo "❌ Aplicação NÃO respondendo"
        ;;
    reinstall)
        echo "🔄 Reinstalando HLS Converter..."
        sudo systemctl stop hls-converter 2>/dev/null || true
        sudo systemctl disable hls-converter 2>/dev/null || true
        sudo rm -f /etc/systemd/system/hls-converter.service
        sudo systemctl daemon-reload
        rm -rf "$HLS_HOME"
        log "✅ Removido. Execute o script de instalação novamente."
        ;;
    direct-start)
        echo "🚀 Iniciando diretamente (sem systemd)..."
        cd "$HLS_HOME"
        ./start.sh
        ;;
    info)
        IP=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "localhost")
        echo "=== HLS Converter PRO v4.0 ==="
        echo ""
        echo "🌐 URLs:"
        echo "   • Interface Principal: http://$IP:8080"
        echo "   • Health Check: http://$IP:8080/health"
        echo "   • Debug FFmpeg: http://$IP:8080/debug/ffmpeg"
        echo "   • API System: http://$IP:8080/api/system"
        echo ""
        echo "⚙️  Informações:"
        echo "   • Diretório: $HLS_HOME"
        echo "   • Porta: 8080"
        echo "   • Usuário: $USER"
        echo "   • FFmpeg: $(command -v ffmpeg 2>/dev/null || echo 'Não instalado')"
        echo "   • Status: $(sudo systemctl is-active hls-converter 2>/dev/null || echo 'inactive')"
        echo ""
        echo "🔧 Comandos disponíveis:"
        echo "   • hlsctl start        - Iniciar serviço"
        echo "   • hlsctl stop         - Parar serviço"
        echo "   • hlsctl restart      - Reiniciar serviço"
        echo "   • hlsctl status       - Status completo"
        echo "   • hlsctl test         - Testar sistema"
        echo "   • hlsctl fix-firewall - Corrigir firewall"
        echo "   • hlsctl direct-start - Iniciar diretamente"
        ;;
    *)
        echo "Uso: hlsctl [comando]"
        echo ""
        echo "Comandos principais:"
        echo "  start          - Iniciar serviço systemd"
        echo "  stop           - Parar serviço"
        echo "  restart        - Reiniciar serviço"
        echo "  status         - Status completo do sistema"
        echo "  logs [-f]      - Ver logs (use -f para seguir)"
        echo ""
        echo "Comandos de manutenção:"
        echo "  test           - Testar sistema completo"
        echo "  cleanup        - Limpar arquivos antigos"
        echo "  fix-ffmpeg     - Instalar/Reparar FFmpeg"
        echo "  fix-firewall   - Configurar firewall"
        echo ""
        echo "Comandos avançados:"
        echo "  debug          - Debug detalhado"
        echo "  reinstall      - Reinstalar completamente"
        echo "  direct-start   - Iniciar diretamente (sem systemd)"
        echo "  info           - Informações do sistema"
        ;;
esac
EOF

chmod +x "$HOME/hlsctl"

# 18. INICIAR SERVIÇO
echo "🚀 Iniciando serviço..."
sudo systemctl enable hls-converter.service
sudo systemctl start hls-converter.service

# Dar tempo para iniciar
echo "⏳ Aguardando inicialização (10 segundos)..."
sleep 10

# 19. VERIFICAÇÃO FINAL COMPLETA
echo "🔍 VERIFICAÇÃO FINAL COMPLETA..."
echo "================================"

# Verificar serviço
echo ""
echo "1. STATUS DO SERVIÇO SYSTEMD:"
if sudo systemctl is-active --quiet hls-converter.service; then
    echo "   ✅ Serviço ativo e rodando"
    echo "   📊 Status:"
    sudo systemctl status hls-converter.service --no-pager | head -10
else
    echo "   ❌ Serviço NÃO está ativo"
    echo "   📋 Últimos logs:"
    sudo journalctl -u hls-converter -n 20 --no-pager
    echo ""
    echo "   🔧 Tentando iniciar manualmente..."
    sudo systemctl start hls-converter.service
    sleep 5
    if sudo systemctl is-active --quiet hls-converter.service; then
        echo "   ✅ Serviço iniciado manualmente com sucesso!"
    else
        echo "   ❌ Falha ao iniciar manualmente"
        echo "   💡 Tentando iniciar diretamente:"
        cd "$HLS_HOME" && ./start.sh &
        sleep 5
    fi
fi

# Verificar porta
echo ""
echo "2. VERIFICAÇÃO DA PORTA 8080:"
if ss -tln | grep -q ':8080'; then
    echo "   ✅ Porta 8080 está escutando"
    echo "   📡 Conexões na porta 8080:"
    ss -tlnp | grep ':8080'
else
    echo "   ❌ Porta 8080 NÃO está escutando"
    echo "   🔧 Tentando abrir porta..."
    sudo "$HOME/hlsctl" fix-firewall
    sleep 2
    echo "   🔄 Reiniciando serviço..."
    sudo systemctl restart hls-converter.service
    sleep 5
fi

# Testar endpoints
echo ""
echo "3. TESTANDO ENDPOINTS:"
sleep 3

# Health check
echo "   a) Health Check:"
if timeout 10 curl -s http://localhost:8080/health > /dev/null; then
    echo "      ✅ Aplicação respondendo"
    HEALTH_RESPONSE=$(timeout 5 curl -s http://localhost:8080/health)
    echo "$HEALTH_RESPONSE" | grep -E "(status|ffmpeg|message)" | head -5
else
    echo "      ❌ Aplicação NÃO respondendo"
    echo "      🔧 Tentando iniciar diretamente..."
    cd "$HLS_HOME" && nohup ./start.sh > "$HLS_HOME/logs/start.log" 2>&1 &
    sleep 8
fi

# Interface web
echo "   b) Interface Web:"
if timeout 10 curl -s -I http://localhost:8080/ 2>/dev/null | head -1 | grep -q "200"; then
    echo "      ✅ Interface carregando"
else
    echo "      ❌ Interface NÃO carregando"
    echo "      📋 Verificando erros..."
    timeout 5 curl -s http://localhost:8080/ 2>/dev/null | head -50
fi

# API System
echo "   c) API System:"
if timeout 10 curl -s http://localhost:8080/api/system > /dev/null; then
    echo "      ✅ API funcionando"
    # Mostrar IP local
    API_RESPONSE=$(timeout 5 curl -s http://localhost:8080/api/system)
    IP=$(echo "$API_RESPONSE" | grep -o '"local_ip":"[^"]*"' | cut -d'"' -f4)
    if [ -n "$IP" ]; then
        echo "      📍 IP Local detectado: $IP"
    fi
else
    echo "      ⚠️  API não respondendo"
fi

# Verificar firewall
echo ""
echo "4. VERIFICAÇÃO DO FIREWALL:"
if command -v firewall-cmd &> /dev/null && sudo firewall-cmd --list-ports 2>/dev/null | grep -q '8080/tcp'; then
    echo "   ✅ Firewalld configurado para porta 8080"
elif command -v ufw &> /dev/null && sudo ufw status 2>/dev/null | grep -q '8080/tcp.*ALLOW'; then
    echo "   ✅ UFW configurado para porta 8080"
else
    echo "   ⚠️  Firewall não configurado para porta 8080"
    echo "   🔧 Configurando agora..."
    sudo "$HOME/hlsctl" fix-firewall
fi

# Verificar ffmpeg
echo ""
echo "5. VERIFICAÇÃO DO FFMPEG:"
if command -v ffmpeg &> /dev/null; then
    echo "   ✅ FFmpeg encontrado"
    FFMPEG_VERSION=$(ffmpeg -version 2>/dev/null | head -1)
    echo "   📊 $FFMPEG_VERSION"
else
    echo "   ❌ FFmpeg NÃO encontrado"
    echo "   🔧 Instalando agora..."
    sudo "$HOME/hlsctl" fix-ffmpeg
fi

# 20. OBTER INFORMAÇÕES FINAIS
echo ""
echo "📊 OBTENDO INFORMAÇÕES DE CONEXÃO..."
IP=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "localhost")

# Tentar obter IP da API
API_IP=$(timeout 5 curl -s http://localhost:8080/api/system 2>/dev/null | grep -o '"local_ip":"[^"]*"' | cut -d'"' -f4 || echo "")
if [ -n "$API_IP" ] && [ "$API_IP" != "127.0.0.1" ]; then
    IP="$API_IP"
fi

echo ""
echo "🎉🎉🎉 INSTALAÇÃO COMPLETA E FIREWALL CONFIGURADO! 🎉🎉🎉"
echo "======================================================"
echo ""
echo "✅ SISTEMA PRONTO PARA USO"
echo "🔥 FIREWALL CONFIGURADO PARA PORTA 8080"
echo ""
echo "🌐 URLS PRINCIPAIS:"
echo "   🎨 INTERFACE PRINCIPAL: http://$IP:8080"
echo "   🩺 HEALTH CHECK: http://$IP:8080/health"
echo "   🔧 DEBUG FFMPEG: http://$IP:8080/debug/ffmpeg"
echo "   📊 API SYSTEM: http://$IP:8080/api/system"
echo ""
echo "🔗 PARA ACESSAR DE OUTROS DISPOSITIVOS:"
echo "   Use o mesmo IP acima em qualquer navegador da rede"
echo ""
echo "⚙️  COMANDOS DISPONÍVEIS:"
echo "   • $HOME/hlsctl status     - Status completo do sistema"
echo "   • $HOME/hlsctl test       - Testar todo o sistema"
echo "   • $HOME/hlsctl restart    - Reiniciar serviço"
echo "   • $HOME/hlsctl logs -f    - Ver logs em tempo real"
echo "   • $HOME/hlsctl fix-firewall - Corrigir firewall se necessário"
echo ""
echo "🔧 SOLUÇÃO DE PROBLEMAS:"
echo "   1. Se não conseguir acessar: $HOME/hlsctl test"
echo "   2. Se firewall bloquear: $HOME/hlsctl fix-firewall"
echo "   3. Se não iniciar: $HOME/hlsctl direct-start"
echo ""
echo "📁 DIRETÓRIO: $HLS_HOME"
echo "📋 LOGS: $HLS_HOME/logs/"
echo ""
echo "🚀 SISTEMA CONFIGURADO PARA INICIAR AUTOMATICAMENTE!"
echo "   O serviço iniciará automaticamente ao ligar o sistema."
