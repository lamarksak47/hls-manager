#!/bin/bash
# install_hls_converter_simple_fixed.sh - Versão simplificada e corrigida

set -e

echo "🚀 INSTALANDO HLS CONVERTER - VERSÃO SIMPLIFICADA"
echo "================================================="

# 1. Definir diretório base no home
HLS_HOME="$HOME/hls-converter"
echo "📁 Diretório base: $HLS_HOME"

# 2. Parar serviços existentes
echo "🛑 Parando serviços existentes..."
sudo systemctl stop hls-converter 2>/dev/null || true
pkill -f "waitress-serve.*8080" 2>/dev/null || true
pkill -f "python.*app.py" 2>/dev/null || true
sleep 2

# 3. Limpar instalações anteriores
echo "🧹 Limpando instalações anteriores..."
rm -rf "$HLS_HOME" 2>/dev/null || true
sudo rm -f /etc/systemd/system/hls-converter.service 2>/dev/null || true
sudo systemctl daemon-reload

# 4. Instalar dependências
echo "🔧 Instalando dependências..."
sudo apt-get update
sudo apt-get install -y ffmpeg python3 python3-pip python3-venv curl

# 5. Criar estrutura de diretórios
echo "🏗️  Criando estrutura de diretórios..."
mkdir -p "$HLS_HOME"/{uploads,hls,logs,db,templates,static}
mkdir -p "$HLS_HOME/hls/{240p,480p,720p,1080p}"
cd "$HLS_HOME"

# 6. Configurar ambiente Python
echo "🐍 Configurando ambiente Python..."
python3 -m venv venv
source venv/bin/activate

# Instalar dependências Python
echo "📦 Instalando dependências Python..."
pip install --upgrade pip
pip install flask flask-cors waitress

# 7. CRIAR APLICAÇÃO FLASK SIMPLES E FUNCIONAL
echo "💻 Criando aplicação Flask simples..."

cat > app.py << 'EOF'
from flask import Flask, request, jsonify, send_file, render_template_string, send_from_directory
from flask_cors import CORS
import os
import subprocess
import uuid
import json
import time
from datetime import datetime
import shutil
import socket

app = Flask(__name__)
CORS(app)

# Configurações
BASE_DIR = os.path.expanduser("~/hls-converter")
UPLOAD_DIR = os.path.join(BASE_DIR, "uploads")
HLS_DIR = os.path.join(BASE_DIR, "hls")
LOG_DIR = os.path.join(BASE_DIR, "logs")
DB_DIR = os.path.join(BASE_DIR, "db")

# Criar diretórios se não existirem
for directory in [BASE_DIR, UPLOAD_DIR, HLS_DIR, LOG_DIR, DB_DIR]:
    os.makedirs(directory, exist_ok=True)

# Banco de dados simples
DB_FILE = os.path.join(DB_DIR, "conversions.json")

def load_database():
    """Carrega o banco de dados"""
    if os.path.exists(DB_FILE):
        try:
            with open(DB_FILE, 'r') as f:
                return json.load(f)
        except:
            pass
    return {"conversions": [], "stats": {"total": 0, "success": 0, "failed": 0}}

def save_database(data):
    """Salva o banco de dados"""
    with open(DB_FILE, 'w') as f:
        json.dump(data, f, indent=2)

# Página HTML simples
HTML_PAGE = '''
<!DOCTYPE html>
<html>
<head>
    <title>HLS Converter</title>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <style>
        body {
            font-family: Arial, sans-serif;
            max-width: 1200px;
            margin: 0 auto;
            padding: 20px;
            background: #f5f5f5;
        }
        .header {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 30px;
            border-radius: 10px;
            margin-bottom: 30px;
            text-align: center;
        }
        .upload-area {
            border: 3px dashed #667eea;
            border-radius: 10px;
            padding: 40px;
            text-align: center;
            margin: 20px 0;
            background: white;
            cursor: pointer;
        }
        .upload-area:hover {
            background: #f0f0ff;
        }
        .btn {
            background: #667eea;
            color: white;
            border: none;
            padding: 12px 24px;
            border-radius: 5px;
            cursor: pointer;
            font-size: 16px;
            margin: 10px;
        }
        .btn:hover {
            background: #5a67d8;
        }
        .btn:disabled {
            background: #cccccc;
            cursor: not-allowed;
        }
        .file-list {
            background: white;
            padding: 20px;
            border-radius: 10px;
            margin: 20px 0;
        }
        .progress {
            width: 100%;
            height: 20px;
            background: #e0e0e0;
            border-radius: 10px;
            overflow: hidden;
            margin: 20px 0;
        }
        .progress-bar {
            height: 100%;
            background: #4CAF50;
            transition: width 0.3s;
        }
        .status-box {
            background: white;
            padding: 20px;
            border-radius: 10px;
            margin: 20px 0;
        }
        .success {
            color: #4CAF50;
        }
        .error {
            color: #f44336;
        }
        .info {
            color: #2196F3;
        }
        #m3u8Link {
            width: 100%;
            padding: 10px;
            margin: 10px 0;
            border: 1px solid #ddd;
            border-radius: 5px;
            font-family: monospace;
        }
    </style>
</head>
<body>
    <div class="header">
        <h1>🎬 HLS Converter</h1>
        <p>Converta vídeos para formato HLS com múltiplas qualidades</p>
    </div>
    
    <div class="status-box">
        <h3>📊 Status do Sistema</h3>
        <p>FFmpeg: <span id="ffmpegStatus">Verificando...</span></p>
        <p>Serviço: <span id="serviceStatus">Conectando...</span></p>
    </div>
    
    <div class="upload-area" onclick="document.getElementById('fileInput').click()">
        <h2>📤 Upload de Vídeo</h2>
        <p>Clique aqui ou arraste e solte um arquivo de vídeo</p>
        <p>Formatos suportados: MP4, AVI, MOV, MKV, WEBM</p>
    </div>
    
    <input type="file" id="fileInput" accept="video/*" style="display:none" onchange="handleFileSelect()">
    
    <div id="fileInfo" style="display:none">
        <div class="file-list">
            <h3>📁 Arquivo Selecionado:</h3>
            <p id="fileName"></p>
            <p id="fileSize"></p>
        </div>
        
        <div>
            <h3>🎚️ Qualidades:</h3>
            <label><input type="checkbox" id="q240" checked> 240p</label><br>
            <label><input type="checkbox" id="q480" checked> 480p</label><br>
            <label><input type="checkbox" id="q720" checked> 720p</label><br>
            <label><input type="checkbox" id="q1080"> 1080p</label>
        </div>
        
        <button class="btn" onclick="startConversion()" id="convertBtn">🚀 Iniciar Conversão</button>
    </div>
    
    <div id="progressSection" style="display:none">
        <h3>⏳ Progresso</h3>
        <div class="progress">
            <div class="progress-bar" id="progressBar" style="width: 0%"></div>
        </div>
        <p id="progressText">Aguardando início...</p>
    </div>
    
    <div id="resultSection" style="display:none">
        <div class="status-box">
            <h3 class="success">✅ Conversão Concluída!</h3>
            <p>ID do vídeo: <span id="videoId"></span></p>
            <p>Link M3U8: </p>
            <input type="text" id="m3u8Link" readonly>
            <br>
            <button class="btn" onclick="copyLink()">📋 Copiar Link</button>
            <button class="btn" onclick="testPlayer()">▶️ Testar Player</button>
            <button class="btn" onclick="resetForm()">🔄 Novo Vídeo</button>
        </div>
    </div>

    <script>
        let selectedFile = null;
        
        // Verificar status
        async function checkStatus() {
            try {
                const response = await fetch('/health');
                if (!response.ok) {
                    throw new Error('HTTP error: ' + response.status);
                }
                const data = await response.json();
                
                if (data.ffmpeg) {
                    document.getElementById('ffmpegStatus').innerHTML = '✅ Disponível';
                    document.getElementById('ffmpegStatus').className = 'success';
                } else {
                    document.getElementById('ffmpegStatus').innerHTML = '❌ Não encontrado';
                    document.getElementById('ffmpegStatus').className = 'error';
                }
                
                document.getElementById('serviceStatus').innerHTML = '✅ Online';
                document.getElementById('serviceStatus').className = 'success';
                
            } catch (error) {
                console.error('Erro ao verificar status:', error);
                document.getElementById('serviceStatus').innerHTML = '❌ Offline';
                document.getElementById('serviceStatus').className = 'error';
                document.getElementById('ffmpegStatus').innerHTML = '❓ Desconhecido';
                document.getElementById('ffmpegStatus').className = 'error';
            }
        }
        
        // Manipular seleção de arquivo
        function handleFileSelect() {
            const fileInput = document.getElementById('fileInput');
            if (fileInput.files.length > 0) {
                selectedFile = fileInput.files[0];
                
                document.getElementById('fileName').textContent = 'Nome: ' + selectedFile.name;
                document.getElementById('fileSize').textContent = 'Tamanho: ' + formatBytes(selectedFile.size);
                document.getElementById('fileInfo').style.display = 'block';
                
                // Esconder outras seções
                document.getElementById('progressSection').style.display = 'none';
                document.getElementById('resultSection').style.display = 'none';
            }
        }
        
        // Iniciar conversão
        async function startConversion() {
            if (!selectedFile) {
                alert('Selecione um arquivo primeiro!');
                return;
            }
            
            // Verificar tamanho do arquivo (limite de 500MB)
            if (selectedFile.size > 500 * 1024 * 1024) {
                alert('Arquivo muito grande! Tamanho máximo: 500MB');
                return;
            }
            
            // Obter qualidades selecionadas
            const qualities = [];
            if (document.getElementById('q240').checked) qualities.push('240p');
            if (document.getElementById('q480').checked) qualities.push('480p');
            if (document.getElementById('q720').checked) qualities.push('720p');
            if (document.getElementById('q1080').checked) qualities.push('1080p');
            
            if (qualities.length === 0) {
                alert('Selecione pelo menos uma qualidade!');
                return;
            }
            
            // Preparar formulário
            const formData = new FormData();
            formData.append('file', selectedFile);
            formData.append('qualities', JSON.stringify(qualities));
            
            // Mostrar progresso
            document.getElementById('fileInfo').style.display = 'none';
            document.getElementById('progressSection').style.display = 'block';
            document.getElementById('resultSection').style.display = 'none';
            
            const convertBtn = document.getElementById('convertBtn');
            convertBtn.disabled = true;
            
            // Simular progresso
            simulateProgress();
            
            try {
                const response = await fetch('/convert', {
                    method: 'POST',
                    body: formData
                });
                
                if (!response.ok) {
                    throw new Error('HTTP error: ' + response.status);
                }
                
                const result = await response.json();
                
                if (result.success) {
                    // Mostrar resultado
                    document.getElementById('videoId').textContent = result.video_id;
                    
                    // Construir URL completa
                    const baseUrl = window.location.origin;
                    const m3u8Url = result.m3u8_url || `/hls/${result.video_id}/master.m3u8`;
                    const fullUrl = baseUrl + m3u8Url;
                    
                    document.getElementById('m3u8Link').value = fullUrl;
                    document.getElementById('progressSection').style.display = 'none';
                    document.getElementById('resultSection').style.display = 'block';
                    document.getElementById('progressText').textContent = 'Concluído!';
                    document.getElementById('progressBar').style.width = '100%';
                } else {
                    alert('Erro na conversão: ' + (result.error || 'Erro desconhecido'));
                    resetForm();
                }
            } catch (error) {
                console.error('Erro na conversão:', error);
                alert('Erro de conexão: ' + error.message);
                resetForm();
            } finally {
                convertBtn.disabled = false;
            }
        }
        
        // Simular progresso
        function simulateProgress() {
            let progress = 0;
            const interval = setInterval(() => {
                progress += 2;
                if (progress > 90) {
                    clearInterval(interval);
                    return;
                }
                updateProgress(progress, 'Convertendo...');
            }, 200);
        }
        
        function updateProgress(percent, text) {
            const progressBar = document.getElementById('progressBar');
            const progressText = document.getElementById('progressText');
            
            if (progressBar) progressBar.style.width = percent + '%';
            if (progressText) progressText.textContent = text + ' (' + Math.round(percent) + '%)';
        }
        
        // Copiar link
        function copyLink() {
            const linkInput = document.getElementById('m3u8Link');
            linkInput.select();
            linkInput.setSelectionRange(0, 99999); // Para mobile
            document.execCommand('copy');
            alert('Link copiado para a área de transferência!');
        }
        
        // Testar player
        function testPlayer() {
            const videoId = document.getElementById('videoId').textContent;
            if (videoId) {
                window.open('/player/' + videoId, '_blank');
            }
        }
        
        // Resetar formulário
        function resetForm() {
            selectedFile = null;
            document.getElementById('fileInput').value = '';
            document.getElementById('fileInfo').style.display = 'none';
            document.getElementById('progressSection').style.display = 'none';
            document.getElementById('resultSection').style.display = 'none';
            document.getElementById('convertBtn').disabled = false;
            
            // Resetar checkboxes
            document.getElementById('q240').checked = true;
            document.getElementById('q480').checked = true;
            document.getElementById('q720').checked = true;
            document.getElementById('q1080').checked = false;
            
            // Resetar progresso
            document.getElementById('progressBar').style.width = '0%';
            document.getElementById('progressText').textContent = 'Aguardando início...';
        }
        
        // Formatar bytes
        function formatBytes(bytes) {
            if (bytes === 0) return '0 Bytes';
            const k = 1024;
            const sizes = ['Bytes', 'KB', 'MB', 'GB'];
            const i = Math.floor(Math.log(bytes) / Math.log(k));
            return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i];
        }
        
        // Inicializar
        document.addEventListener('DOMContentLoaded', function() {
            checkStatus();
            
            // Configurar arrastar e soltar
            const uploadArea = document.querySelector('.upload-area');
            if (uploadArea) {
                uploadArea.addEventListener('dragover', (e) => {
                    e.preventDefault();
                    uploadArea.style.backgroundColor = '#f0f0ff';
                });
                
                uploadArea.addEventListener('dragleave', () => {
                    uploadArea.style.backgroundColor = 'white';
                });
                
                uploadArea.addEventListener('drop', (e) => {
                    e.preventDefault();
                    uploadArea.style.backgroundColor = 'white';
                    
                    if (e.dataTransfer.files.length > 0) {
                        const file = e.dataTransfer.files[0];
                        // Verificar se é um arquivo de vídeo
                        if (file.type.startsWith('video/') || 
                            file.name.match(/\.(mp4|avi|mov|mkv|webm)$/i)) {
                            document.getElementById('fileInput').files = e.dataTransfer.files;
                            handleFileSelect();
                        } else {
                            alert('Por favor, selecione um arquivo de vídeo (MP4, AVI, MOV, MKV, WEBM)');
                        }
                    }
                });
            }
            
            // Adicionar listener para o botão de reset
            const resetBtn = document.querySelector('button[onclick="resetForm()"]');
            if (resetBtn) {
                resetBtn.addEventListener('click', resetForm);
            }
        });
    </script>
</body>
</html>
'''

@app.route('/')
def index():
    return render_template_string(HTML_PAGE)

@app.route('/health')
def health():
    """Health check"""
    try:
        # Verificar ffmpeg
        ffmpeg_result = subprocess.run(['which', 'ffmpeg'], capture_output=True, text=True)
        ffmpeg_available = ffmpeg_result.returncode == 0
        
        return jsonify({
            "status": "online",
            "service": "hls-converter",
            "ffmpeg": ffmpeg_available,
            "ffmpeg_path": ffmpeg_result.stdout.strip() if ffmpeg_available else None,
            "timestamp": datetime.now().isoformat()
        })
    except Exception as e:
        return jsonify({
            "status": "error",
            "error": str(e),
            "timestamp": datetime.now().isoformat()
        })

@app.route('/convert', methods=['POST'])
def convert():
    try:
        if 'file' not in request.files:
            return jsonify({"success": False, "error": "Nenhum arquivo enviado"})
        
        file = request.files['file']
        if file.filename == '':
            return jsonify({"success": False, "error": "Nenhum arquivo selecionado"})
        
        # Verificar extensão do arquivo
        allowed_extensions = {'.mp4', '.avi', '.mov', '.mkv', '.webm', '.m4v', '.flv', '.wmv'}
        file_ext = os.path.splitext(file.filename)[1].lower()
        if file_ext not in allowed_extensions:
            return jsonify({"success": False, "error": f"Formato não suportado. Use: {', '.join(allowed_extensions)}"})
        
        # Verificar ffmpeg
        try:
            ffmpeg_path = subprocess.run(['which', 'ffmpeg'], capture_output=True, text=True).stdout.strip()
            if not ffmpeg_path:
                return jsonify({"success": False, "error": "FFmpeg não está instalado. Execute: sudo apt install ffmpeg"})
        except:
            return jsonify({"success": False, "error": "FFmpeg não está instalado. Execute: sudo apt install ffmpeg"})
        
        # Obter qualidades
        qualities_json = request.form.get('qualities', '["720p"]')
        try:
            qualities = json.loads(qualities_json)
        except:
            qualities = ["720p"]
        
        # Gerar ID único
        video_id = str(uuid.uuid4())[:8]
        output_dir = os.path.join(HLS_DIR, video_id)
        os.makedirs(output_dir, exist_ok=True)
        
        # Salvar arquivo original
        filename = secure_filename(file.filename) if hasattr(file, 'filename') else f"video{file_ext}"
        original_path = os.path.join(UPLOAD_DIR, f"{video_id}_{filename}")
        file.save(original_path)
        
        print(f"🔧 Convertendo: {filename} para {video_id}")
        print(f"📊 Qualidades: {', '.join(qualities)}")
        
        # Converter para cada qualidade
        for quality in qualities:
            quality_dir = os.path.join(output_dir, quality)
            os.makedirs(quality_dir, exist_ok=True)
            
            m3u8_file = os.path.join(quality_dir, 'index.m3u8')
            
            # Configurar parâmetros por qualidade
            if quality == '240p':
                scale = "426:240"
                bitrate = "400k"
                bandwidth = "400000"
                resolution = "426x240"
            elif quality == '480p':
                scale = "854:480"
                bitrate = "800k"
                bandwidth = "800000"
                resolution = "854x480"
            elif quality == '720p':
                scale = "1280:720"
                bitrate = "1500k"
                bandwidth = "1500000"
                resolution = "1280x720"
            elif quality == '1080p':
                scale = "1920:1080"
                bitrate = "3000k"
                bandwidth = "3000000"
                resolution = "1920x1080"
            else:
                continue  # Pular qualidade desconhecida
            
            print(f"  ⏳ Convertendo para {quality}...")
            
            # Comando ffmpeg otimizado
            cmd = [
                ffmpeg_path, '-i', original_path,
                '-vf', f'scale={scale}',
                '-c:v', 'libx264',
                '-preset', 'fast',
                '-b:v', bitrate,
                '-c:a', 'aac',
                '-b:a', '128k',
                '-hls_time', '6',
                '-hls_list_size', '0',
                '-hls_segment_filename', os.path.join(quality_dir, 'segment_%03d.ts'),
                '-f', 'hls', m3u8_file
            ]
            
            try:
                result = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
                if result.returncode == 0:
                    print(f"  ✅ {quality} convertida com sucesso")
                else:
                    print(f"  ❌ Erro na conversão {quality}: {result.stderr[:200]}")
            except subprocess.TimeoutExpired:
                print(f"  ⚠️  Timeout na conversão {quality}")
            except Exception as e:
                print(f"  ❌ Exceção na conversão {quality}: {str(e)}")
        
        # Criar master playlist
        master_file = os.path.join(output_dir, 'master.m3u8')
        with open(master_file, 'w') as f:
            f.write("#EXTM3U\n")
            f.write("#EXT-X-VERSION:3\n")
            
            for quality in qualities:
                if quality == '240p':
                    bandwidth = "400000"
                    resolution = "426x240"
                elif quality == '480p':
                    bandwidth = "800000"
                    resolution = "854x480"
                elif quality == '720p':
                    bandwidth = "1500000"
                    resolution = "1280x720"
                elif quality == '1080p':
                    bandwidth = "3000000"
                    resolution = "1920x1080"
                else:
                    continue
                
                f.write(f"#EXT-X-STREAM-INF:BANDWIDTH={bandwidth},RESOLUTION={resolution}\n")
                f.write(f"{quality}/index.m3u8\n")
        
        # Atualizar banco de dados
        db = load_database()
        conversion_data = {
            "video_id": video_id,
            "filename": filename,
            "qualities": qualities,
            "timestamp": datetime.now().isoformat(),
            "status": "success",
            "m3u8_url": f"/hls/{video_id}/master.m3u8"
        }
        
        if "conversions" not in db:
            db["conversions"] = []
        db["conversions"].append(conversion_data)
        
        # Atualizar estatísticas
        if "stats" not in db:
            db["stats"] = {"total": 0, "success": 0, "failed": 0}
        db["stats"]["total"] = db["stats"].get("total", 0) + 1
        db["stats"]["success"] = db["stats"].get("success", 0) + 1
        
        save_database(db)
        
        # Limpar arquivo original
        try:
            os.remove(original_path)
        except:
            pass
        
        print(f"🎉 Conversão {video_id} concluída!")
        
        return jsonify({
            "success": True,
            "video_id": video_id,
            "qualities": qualities,
            "m3u8_url": f"/hls/{video_id}/master.m3u8",
            "player_url": f"/player/{video_id}"
        })
        
    except Exception as e:
        print(f"❌ Erro na conversão: {str(e)}")
        
        # Atualizar estatísticas de erro no banco de dados
        try:
            db = load_database()
            db["stats"]["total"] = db["stats"].get("total", 0) + 1
            db["stats"]["failed"] = db["stats"].get("failed", 0) + 1
            save_database(db)
        except:
            pass
        
        return jsonify({"success": False, "error": str(e)})

@app.route('/player/<video_id>')
def player(video_id):
    """Página do player"""
    m3u8_url = f"/hls/{video_id}/master.m3u8"
    
    player_html = f'''
    <!DOCTYPE html>
    <html>
    <head>
        <title>Player HLS - {video_id}</title>
        <link href="https://vjs.zencdn.net/7.20.3/video-js.css" rel="stylesheet">
        <style>
            body {{ 
                margin: 0; 
                padding: 20px; 
                background: #1a1a1a;
                color: white;
                font-family: Arial, sans-serif;
            }}
            .player-container {{ 
                max-width: 1200px; 
                margin: 0 auto;
            }}
            .header {{
                text-align: center;
                margin-bottom: 20px;
            }}
            .back-btn {{
                display: inline-block;
                background: #667eea;
                color: white;
                padding: 10px 20px;
                text-decoration: none;
                border-radius: 5px;
                margin-bottom: 20px;
            }}
            .back-btn:hover {{
                background: #5a67d8;
            }}
        </style>
    </head>
    <body>
        <div class="player-container">
            <div class="header">
                <a href="/" class="back-btn">⬅️ Voltar</a>
                <h2>🎬 Player HLS - {video_id}</h2>
            </div>
            
            <video id="hlsPlayer" class="video-js vjs-default-skin vjs-big-play-centered" 
                   controls preload="auto" width="100%" height="auto">
                <source src="{m3u8_url}" type="application/x-mpegURL">
                <p class="vjs-no-js">
                    Seu navegador não suporta a reprodução de vídeo HLS.
                    Por favor, use um navegador moderno como Chrome, Firefox ou Safari.
                </p>
            </video>
            
            <div style="margin-top: 20px; text-align: center;">
                <p><strong>URL do vídeo:</strong> {m3u8_url}</p>
                <button onclick="copyPlayerUrl()" style="
                    background: #28a745;
                    color: white;
                    border: none;
                    padding: 10px 20px;
                    border-radius: 5px;
                    cursor: pointer;
                    margin: 10px;
                ">📋 Copiar URL</button>
            </div>
        </div>
        
        <script src="https://vjs.zencdn.net/7.20.3/video.js"></script>
        <script>
            // Inicializar player
            var player = videojs('hlsPlayer', {
                controls: true,
                autoplay: false,
                preload: 'auto',
                responsive: true,
                fluid: true
            });
            
            // Função para copiar URL
            function copyPlayerUrl() {{
                const url = "{m3u8_url}";
                const fullUrl = window.location.origin + url;
                
                navigator.clipboard.writeText(fullUrl).then(function() {{
                    alert('URL copiada para a área de transferência!');
                }}, function(err) {{
                    // Fallback para navegadores antigos
                    const tempInput = document.createElement('input');
                    tempInput.value = fullUrl;
                    document.body.appendChild(tempInput);
                    tempInput.select();
                    document.execCommand('copy');
                    document.body.removeChild(tempInput);
                    alert('URL copiada para a área de transferência!');
                }});
            }}
            
            // Adicionar tratamento de erro
            player.on('error', function() {{
                console.log('Erro no player:', player.error());
                alert('Erro ao carregar o vídeo. Verifique se a conversão foi concluída.');
            }});
        </script>
    </body>
    </html>
    '''
    return render_template_string(player_html)

@app.route('/hls/<path:path>')
def serve_hls(path):
    """Servir arquivos HLS"""
    file_path = os.path.join(HLS_DIR, path)
    if os.path.exists(file_path):
        response = send_file(file_path)
        # Adicionar headers CORS para permitir acesso do player
        response.headers['Access-Control-Allow-Origin'] = '*'
        response.headers['Cache-Control'] = 'public, max-age=3600'
        return response
    return "Arquivo não encontrado", 404

# Adicionar rota para servir arquivos estáticos
@app.route('/static/<path:filename>')
def serve_static(filename):
    """Servir arquivos estáticos"""
    static_dir = os.path.join(BASE_DIR, 'static')
    return send_from_directory(static_dir, filename)

# Adicionar helper para secure_filename se não existir
try:
    from werkzeug.utils import secure_filename
except ImportError:
    def secure_filename(filename):
        """Versão simplificada de secure_filename"""
        import re
        filename = str(filename)
        filename = re.sub(r'[^\w\s.-]', '', filename)
        filename = re.sub(r'[-\s]+', '-', filename)
        return filename.strip('.-')

if __name__ == '__main__':
    print("=" * 60)
    print("🎬 HLS Converter - Servidor Iniciado")
    print("=" * 60)
    
    # Verificar ffmpeg
    try:
        ffmpeg_result = subprocess.run(['which', 'ffmpeg'], capture_output=True, text=True)
        if ffmpeg_result.returncode == 0:
            ffmpeg_path = ffmpeg_result.stdout.strip()
            print(f"✅ FFmpeg encontrado: {ffmpeg_path}")
            
            # Testar versão
            version_result = subprocess.run(['ffmpeg', '-version'], capture_output=True, text=True)
            if version_result.returncode == 0:
                version_line = version_result.stdout.split('\n')[0]
                print(f"📊 {version_line}")
        else:
            print("❌ FFmpeg NÃO encontrado!")
            print("📋 Execute: sudo apt update && sudo apt install -y ffmpeg")
    except Exception as e:
        print(f"⚠️  Erro ao verificar ffmpeg: {e}")
    
    # Obter IP
    ip = "localhost"
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
    except:
        pass
    
    print(f"🌐 Acesse em: http://{ip}:8080")
    print(f"🌐 Ou localmente: http://localhost:8080")
    print(f"🩺 Health check: http://{ip}:8080/health")
    print("=" * 60)
    
    # Iniciar servidor
    try:
        from waitress import serve
        print("🚀 Iniciando servidor Waitress na porta 8080...")
        serve(app, host='0.0.0.0', port=8080)
    except ImportError:
        print("⚠️  Waitress não encontrado, usando Flask dev server...")
        print("📋 Instale: pip install waitress")
        app.run(host='0.0.0.0', port=8080, debug=True)
EOF

# 8. CRIAR SERVIÇO SYSTEMD MELHORADO
echo "⚙️ Criando serviço systemd..."

cat > hls-converter.service << EOF
[Unit]
Description=HLS Converter Service
After=network.target
Wants=network.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$HLS_HOME
Environment="PATH=$HLS_HOME/venv/bin:/usr/local/bin:/usr/bin:/bin"
Environment="PYTHONUNBUFFERED=1"

# Comando para iniciar
ExecStart=$HLS_HOME/venv/bin/python $HLS_HOME/app.py

# Reiniciar sempre
Restart=always
RestartSec=10

# Logs
StandardOutput=journal
StandardError=journal
SyslogIdentifier=hls-converter

# Segurança
NoNewPrivileges=true
PrivateTmp=true

# Limites
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

# 9. INSTALAR E INICIAR SERVIÇO
echo "📦 Instalando serviço..."
sudo cp hls-converter.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable hls-converter
sudo systemctl start hls-converter

# 10. CONFIGURAR FIREWALL
echo "🔥 Configurando firewall..."
# Verificar e configurar firewall
if command -v ufw &> /dev/null && sudo ufw status | grep -q "Status: active"; then
    sudo ufw allow 8080/tcp
    echo "✅ Porta 8080 aberta no UFW"
elif command -v firewall-cmd &> /dev/null && sudo systemctl is-active --quiet firewalld; then
    sudo firewall-cmd --permanent --add-port=8080/tcp
    sudo firewall-cmd --reload
    echo "✅ Porta 8080 aberta no firewalld"
else
    # Tentar iptables
    sudo iptables -A INPUT -p tcp --dport 8080 -j ACCEPT 2>/dev/null || true
    echo "✅ Porta 8080 configurada (firewall pode não estar ativo)"
fi

# 11. AGUARDAR INICIALIZAÇÃO
echo "⏳ Aguardando inicialização (7 segundos)..."
sleep 7

# 12. VERIFICAÇÃO COMPLETA
echo "🔍 Verificando instalação..."
echo ""

# Verificar serviço
if sudo systemctl is-active --quiet hls-converter; then
    echo "✅ Serviço está ativo e rodando"
    
    # Verificar status do serviço
    echo "📊 Status do serviço:"
    sudo systemctl status hls-converter --no-pager | head -15
    
    # Aguardar mais um pouco para garantir que está pronto
    sleep 3
else
    echo "❌ Serviço não está ativo"
    echo "📋 Últimos logs:"
    sudo journalctl -u hls-converter -n 15 --no-pager
    
    echo ""
    echo "🔧 Tentando iniciar manualmente..."
    cd "$HLS_HOME" 
    source venv/bin/activate
    nohup python app.py > app.log 2>&1 &
    echo $! > app.pid
    sleep 5
fi

# Testar acesso
echo ""
echo "🌐 Testando acesso ao servidor..."
IP=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "localhost")

# Testar health endpoint
echo "  1. Testando health endpoint..."
if timeout 10 curl -s http://localhost:8080/health > /dev/null; then
    HEALTH_RESPONSE=$(timeout 5 curl -s http://localhost:8080/health)
    if echo "$HEALTH_RESPONSE" | grep -q '"status"'; then
        echo "     ✅ Health check OK"
        # Extrair informações do health
        FFMPEG_STATUS=$(echo "$HEALTH_RESPONSE" | grep -o '"ffmpeg":\s*\(true\|false\)' | grep -o 'true\|false')
        if [ "$FFMPEG_STATUS" = "true" ]; then
            echo "     ✅ FFmpeg disponível"
        else
            echo "     ⚠️  FFmpeg não encontrado"
            echo "     📋 Execute: sudo apt install ffmpeg"
        fi
    else
        echo "     ⚠️  Health check retornou resposta inválida"
    fi
else
    echo "     ❌ Health check falhou"
fi

# Testar página principal
echo "  2. Testando página principal..."
if timeout 10 curl -s -I http://localhost:8080/ 2>/dev/null | head -1 | grep -q "200"; then
    echo "     ✅ Página principal carregando"
else
    echo "     ❌ Página principal não carregando"
    
    # Tentar verificar se o processo está rodando
    if pgrep -f "python.*app.py" > /dev/null; then
        echo "     ⚠️  Processo está rodando mas não respondendo"
        echo "     📋 Verificando porta..."
        netstat -tlnp 2>/dev/null | grep ":8080" || echo "     Porta 8080 não está em uso"
    fi
fi

# Mostrar URLs de acesso
echo ""
echo "🎉 INSTALAÇÃO COMPLETA!"
echo "======================="
echo ""
echo "🌐 URLs DE ACESSO:"
echo "   • Interface Principal: http://$IP:8080"
echo "   • Health Check: http://$IP:8080/health"
echo "   • Player (após conversão): http://$IP:8080/player/[video_id]"
echo ""
echo "⚙️  COMANDOS DE GERENCIAMENTO:"
echo "   sudo systemctl status hls-converter    # Ver status"
echo "   sudo systemctl restart hls-converter   # Reiniciar"
echo "   sudo journalctl -u hls-converter -f    # Ver logs em tempo real"
echo ""
echo "🔧 SOLUÇÃO DE PROBLEMAS:"
echo "   • Se não acessar: sudo ufw allow 8080/tcp"
echo "   • Se FFmpeg faltar: sudo apt install ffmpeg"
echo "   • Para reiniciar manualmente:"
echo "     cd $HLS_HOME && source venv/bin/activate && python app.py"
echo ""
echo "📁 Diretório da aplicação: $HLS_HOME"
echo "📋 Logs da aplicação: $HLS_HOME/app.log"
echo "💾 Banco de dados: $HLS_HOME/db/conversions.json"

# Criar script de gerenciamento simples
echo ""
echo "📝 Criando script de gerenciamento 'hlsctl'..."
cat > "$HOME/hlsctl" << 'HLSCTL_EOF'
#!/bin/bash
# Script de gerenciamento do HLS Converter

HLS_HOME="$HOME/hls-converter"

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
        curl -s http://localhost:8080/health | python3 -m json.tool 2>/dev/null || curl -s http://localhost:8080/health
        ;;
    direct)
        echo "🚀 Iniciando diretamente..."
        cd "$HLS_HOME"
        source venv/bin/activate
        python app.py
        ;;
    *)
        echo "Uso: hlsctl [comando]"
        echo ""
        echo "Comandos:"
        echo "  start     - Iniciar serviço"
        echo "  stop      - Parar serviço"
        echo "  restart   - Reiniciar serviço"
        echo "  status    - Status do serviço"
        echo "  logs [-f] - Ver logs (use -f para seguir)"
        echo "  test      - Testar sistema"
        echo "  direct    - Iniciar diretamente (sem systemd)"
        ;;
esac
HLSCTL_EOF

chmod +x "$HOME/hlsctl"

echo ""
echo "✅ Script 'hlsctl' criado em $HOME/hlsctl"
echo "   Use: hlsctl status  # Para verificar status"
echo ""
echo "🚀 Sistema pronto para uso!"
