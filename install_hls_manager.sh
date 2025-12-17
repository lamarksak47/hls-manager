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
import psutil
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
            <p>Link M3U8: <input type="text" id="m3u8Link" style="width:100%;padding:10px;margin:10px 0" readonly></p>
            <button class="btn" onclick="copyLink()">📋 Copiar Link</button>
            <button class="btn" onclick="testPlayer()">▶️ Testar Player</button>
        </div>
    </div>
    
    <script>
        let selectedFile = null;
        
        // Verificar status
        async function checkStatus() {
            try {
                const response = await fetch('/health');
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
                document.getElementById('serviceStatus').innerHTML = '❌ Offline';
                document.getElementById('serviceStatus').className = 'error';
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
            }
        }
        
        // Iniciar conversão
        async function startConversion() {
            if (!selectedFile) {
                alert('Selecione um arquivo primeiro!');
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
            document.getElementById('progressSection').style.display = 'block';
            document.getElementById('convertBtn').disabled = true;
            
            try {
                const response = await fetch('/convert', {
                    method: 'POST',
                    body: formData
                });
                
                const result = await response.json();
                
                if (result.success) {
                    // Mostrar resultado
                    document.getElementById('videoId').textContent = result.video_id;
                    document.getElementById('m3u8Link').value = window.location.origin + result.m3u8_url;
                    document.getElementById('resultSection').style.display = 'block';
                    document.getElementById('progressText').textContent = 'Concluído!';
                    document.getElementById('progressBar').style.width = '100%';
                } else {
                    alert('Erro: ' + (result.error || 'Conversão falhou'));
                }
            } catch (error) {
                alert('Erro de conexão: ' + error.message);
            } finally {
                document.getElementById('convertBtn').disabled = false;
            }
        }
        
        // Copiar link
        function copyLink() {
            const linkInput = document.getElementById('m3u8Link');
            linkInput.select();
            document.execCommand('copy');
            alert('Link copiado!');
        }
        
        // Testar player
        function testPlayer() {
            const videoId = document.getElementById('videoId').textContent;
            window.open('/player/' + videoId, '_blank');
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
                    document.getElementById('fileInput').files = e.dataTransfer.files;
                    handleFileSelect();
                }
            });
        });
    </script>
</body>
</html>
'''

@app.route('/')
def index():
    return HTML_PAGE

@app.route('/health')
def health():
    """Health check"""
    ffmpeg_available = subprocess.run(['which', 'ffmpeg'], capture_output=True).returncode == 0
    
    return jsonify({
        "status": "online",
        "service": "hls-converter",
        "ffmpeg": ffmpeg_available,
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
        
        # Verificar ffmpeg
        ffmpeg_path = subprocess.run(['which', 'ffmpeg'], capture_output=True, text=True).stdout.strip()
        if not ffmpeg_path:
            return jsonify({"success": False, "error": "FFmpeg não está instalado"})
        
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
        filename = file.filename
        original_path = os.path.join(UPLOAD_DIR, f"{video_id}_{filename}")
        file.save(original_path)
        
        print(f"Convertendo: {filename} para {video_id}")
        
        # Converter para cada qualidade
        for quality in qualities:
            quality_dir = os.path.join(output_dir, quality)
            os.makedirs(quality_dir, exist_ok=True)
            
            m3u8_file = os.path.join(quality_dir, 'index.m3u8')
            
            if quality == '240p':
                cmd = [
                    ffmpeg_path, '-i', original_path,
                    '-vf', 'scale=426:240',
                    '-c:v', 'libx264', '-preset', 'fast',
                    '-c:a', 'aac',
                    '-hls_time', '4',
                    '-hls_list_size', '0',
                    '-f', 'hls', m3u8_file
                ]
            elif quality == '480p':
                cmd = [
                    ffmpeg_path, '-i', original_path,
                    '-vf', 'scale=854:480',
                    '-c:v', 'libx264', '-preset', 'fast',
                    '-c:a', 'aac',
                    '-hls_time', '4',
                    '-hls_list_size', '0',
                    '-f', 'hls', m3u8_file
                ]
            elif quality == '720p':
                cmd = [
                    ffmpeg_path, '-i', original_path,
                    '-vf', 'scale=1280:720',
                    '-c:v', 'libx264', '-preset', 'fast',
                    '-c:a', 'aac',
                    '-hls_time', '4',
                    '-hls_list_size', '0',
                    '-f', 'hls', m3u8_file
                ]
            elif quality == '1080p':
                cmd = [
                    ffmpeg_path, '-i', original_path,
                    '-vf', 'scale=1920:1080',
                    '-c:v', 'libx264', '-preset', 'fast',
                    '-c:a', 'aac',
                    '-hls_time', '4',
                    '-hls_list_size', '0',
                    '-f', 'hls', m3u8_file
                ]
            else:
                continue
            
            # Executar conversão
            try:
                result = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
                if result.returncode != 0:
                    print(f"Erro na conversão {quality}: {result.stderr[:200]}")
            except subprocess.TimeoutExpired:
                print(f"Timeout na conversão {quality}")
        
        # Criar master playlist
        master_file = os.path.join(output_dir, 'master.m3u8')
        with open(master_file, 'w') as f:
            f.write("#EXTM3U\n")
            f.write("#EXT-X-VERSION:3\n")
            for quality in qualities:
                f.write(f"#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=854x480\n")
                f.write(f"{quality}/index.m3u8\n")
        
        # Atualizar banco de dados
        db = load_database()
        db["conversions"].append({
            "video_id": video_id,
            "filename": filename,
            "timestamp": datetime.now().isoformat(),
            "status": "success"
        })
        db["stats"]["total"] += 1
        db["stats"]["success"] += 1
        save_database(db)
        
        # Limpar arquivo original
        try:
            os.remove(original_path)
        except:
            pass
        
        return jsonify({
            "success": True,
            "video_id": video_id,
            "m3u8_url": f"/hls/{video_id}/master.m3u8"
        })
        
    except Exception as e:
        print(f"Erro na conversão: {str(e)}")
        return jsonify({"success": False, "error": str(e)})

@app.route('/player/<video_id>')
def player(video_id):
    """Página do player"""
    player_html = f'''
    <!DOCTYPE html>
    <html>
    <head>
        <title>Player HLS - {video_id}</title>
        <link href="https://vjs.zencdn.net/7.20.3/video-js.css" rel="stylesheet">
        <style>
            body {{ margin: 0; padding: 20px; background: #000; }}
            .player-container {{ max-width: 1000px; margin: 0 auto; }}
        </style>
    </head>
    <body>
        <div class="player-container">
            <video id="hlsPlayer" class="video-js vjs-default-skin" controls preload="auto" width="100%" height="auto">
                <source src="/hls/{video_id}/master.m3u8" type="application/x-mpegURL">
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
    return player_html

@app.route('/hls/<path:path>')
def serve_hls(path):
    """Servir arquivos HLS"""
    file_path = os.path.join(HLS_DIR, path)
    if os.path.exists(file_path):
        return send_file(file_path)
    return "Arquivo não encontrado", 404

if __name__ == '__main__':
    print("=" * 50)
    print("🎬 HLS Converter - Servidor Iniciado")
    print("=" * 50)
    
    # Verificar ffmpeg
    ffmpeg_path = subprocess.run(['which', 'ffmpeg'], capture_output=True, text=True).stdout.strip()
    if ffmpeg_path:
        print(f"✅ FFmpeg encontrado: {ffmpeg_path}")
    else:
        print("❌ FFmpeg NÃO encontrado!")
        print("   Instale com: sudo apt-get install ffmpeg")
    
    # Obter IP
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
    except:
        ip = "localhost"
    
    print(f"🌐 Acesse em: http://{ip}:8080")
    print(f"🌐 Ou localmente: http://localhost:8080")
    print(f"🩺 Health check: http://{ip}:8080/health")
    print("=" * 50)
    
    from waitress import serve
    serve(app, host='0.0.0.0', port=8080)
EOF

# 8. CRIAR SERVIÇO SYSTEMD SIMPLES
echo "⚙️ Criando serviço systemd..."

cat > hls-converter.service << EOF
[Unit]
Description=HLS Converter Service
After=network.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$HLS_HOME
Environment="PATH=$HLS_HOME/venv/bin"
ExecStart=$HLS_HOME/venv/bin/python $HLS_HOME/app.py
Restart=always
RestartSec=10

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
if command -v ufw &> /dev/null; then
    sudo ufw allow 8080/tcp
    echo "✅ Porta 8080 aberta no UFW"
elif command -v firewall-cmd &> /dev/null; then
    sudo firewall-cmd --permanent --add-port=8080/tcp
    sudo firewall-cmd --reload
    echo "✅ Porta 8080 aberta no firewalld"
else
    # Configurar iptables diretamente
    sudo iptables -A INPUT -p tcp --dport 8080 -j ACCEPT 2>/dev/null || true
    echo "✅ Porta 8080 aberta via iptables"
fi

# 11. AGUARDAR INICIALIZAÇÃO
echo "⏳ Aguardando inicialização (5 segundos)..."
sleep 5

# 12. VERIFICAÇÃO
echo "🔍 Verificando instalação..."

# Verificar serviço
if sudo systemctl is-active --quiet hls-converter; then
    echo "✅ Serviço está ativo"
else
    echo "❌ Serviço não está ativo"
    echo "📋 Logs:"
    sudo journalctl -u hls-converter -n 10 --no-pager
    echo "🔧 Tentando iniciar manualmente..."
    cd "$HLS_HOME" && $HLS_HOME/venv/bin/python app.py &
    sleep 3
fi

# Testar acesso
echo "🌐 Testando acesso..."
IP=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "localhost")

if curl -s http://localhost:8080/health > /dev/null; then
    echo "✅ Aplicação respondendo"
    echo ""
    echo "🎉 INSTALAÇÃO COMPLETA!"
    echo "======================="
    echo ""
    echo "🌐 ACESSE A INTERFACE EM:"
    echo "   http://$IP:8080"
    echo "   ou"
    echo "   http://localhost:8080"
    echo ""
    echo "⚙️  COMANDOS ÚTEIS:"
    echo "   sudo systemctl status hls-converter"
    echo "   sudo journalctl -u hls-converter -f"
    echo "   sudo systemctl restart hls-converter"
    echo ""
    echo "📁 Diretório: $HLS_HOME"
else
    echo "⚠️  Aplicação não está respondendo"
    echo "🔧 Iniciando manualmente..."
    cd "$HLS_HOME"
    $HLS_HOME/venv/bin/python app.py
fi
