#!/bin/bash
# install_hls_converter_final.sh - Versão corrigida para home directory

set -e

echo "🚀 INSTALANDO HLS CONVERTER - HOME DIRECTORY VERSION"
echo "=================================================="

# 1. Definir diretório base (home do usuário)
HLS_HOME="$HOME/hls-converter"
echo "📁 Diretório base: $HLS_HOME"

# 2. Verificar sistema
echo "🔍 Verificando sistema..."
if mount | grep " / " | grep -q "ro,"; then
    echo "⚠️  Sistema de arquivos root está SOMENTE LEITURA! Corrigindo..."
    sudo mount -o remount,rw /
    echo "✅ Sistema de arquivos agora é leitura/gravação"
fi

# 3. Parar serviços existentes
echo "🛑 Parando serviços existentes..."
sudo systemctl stop hls-converter hls-simple hls-dashboard 2>/dev/null || true
sudo pkill -9 python 2>/dev/null || true
sleep 2

# 4. Limpar instalações anteriores
echo "🧹 Limpando instalações anteriores..."
rm -rf "$HLS_HOME" 2>/dev/null || true
sudo rm -f /etc/systemd/system/hls-*.service 2>/dev/null || true
sudo systemctl daemon-reload

# 5. Atualizar sistema
echo "📦 Atualizando sistema..."
sudo apt-get update
sudo apt-get upgrade -y

# 6. Instalar dependências
echo "🔧 Instalando dependências..."
sudo apt-get install -y python3 python3-pip python3-venv ffmpeg curl

# 7. Criar estrutura
echo "🏗️  Criando estrutura de diretórios..."
mkdir -p "$HLS_HOME"/{uploads,hls,logs,db}
cd "$HLS_HOME"

# 8. Criar usuário (opcional, agora usando usuário atual)
echo "👤 Usando usuário atual: $USER"

# 9. Configurar ambiente Python
echo "🐍 Configurando ambiente Python..."
python3 -m venv venv
source venv/bin/activate

# Instalar dependências Python
pip install --upgrade pip
pip install flask werkzeug psutil

# 10. CRIAR APLICAÇÃO FLASK SIMPLES E FUNCIONAL
echo "💻 Criando aplicação simples e funcional..."

cat > app.py << 'EOF'
from flask import Flask, request, jsonify, send_file, render_template_string, send_from_directory
import os
import subprocess
import uuid
import json
import time
import psutil
from datetime import datetime
import shutil

app = Flask(__name__)

# Configurações - usando diretório home
BASE_DIR = os.path.expanduser("~/hls-converter")
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

# HTML SIMPLES E FUNCIONAL
HTML = '''
<!DOCTYPE html>
<html>
<head>
    <title>🎬 HLS Converter</title>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
            padding: 20px;
            color: #333;
        }
        .container {
            max-width: 1200px;
            margin: 0 auto;
            background: rgba(255, 255, 255, 0.95);
            border-radius: 20px;
            padding: 30px;
            box-shadow: 0 20px 60px rgba(0,0,0,0.3);
        }
        h1 {
            text-align: center;
            margin-bottom: 30px;
            color: #333;
        }
        .upload-area {
            border: 3px dashed #4361ee;
            border-radius: 15px;
            padding: 60px 20px;
            text-align: center;
            cursor: pointer;
            background: rgba(67, 97, 238, 0.05);
            margin-bottom: 30px;
            transition: all 0.3s;
        }
        .upload-area:hover {
            background: rgba(67, 97, 238, 0.1);
            border-color: #3a0ca3;
        }
        .file-list {
            margin: 20px 0;
        }
        .file-item {
            background: #f8f9fa;
            padding: 15px;
            border-radius: 10px;
            margin-bottom: 10px;
            display: flex;
            justify-content: space-between;
            align-items: center;
            border-left: 4px solid #4361ee;
        }
        .btn {
            background: linear-gradient(90deg, #4361ee 0%, #3a0ca3 100%);
            color: white;
            border: none;
            padding: 12px 30px;
            border-radius: 10px;
            font-size: 16px;
            font-weight: bold;
            cursor: pointer;
            transition: transform 0.2s;
        }
        .btn:hover {
            transform: translateY(-2px);
        }
        .btn:disabled {
            opacity: 0.5;
            cursor: not-allowed;
        }
        .progress-container {
            background: #e9ecef;
            border-radius: 10px;
            height: 20px;
            overflow: hidden;
            margin: 20px 0;
            display: none;
        }
        .progress-bar {
            height: 100%;
            background: linear-gradient(90deg, #4cc9f0 0%, #4361ee 100%);
            width: 0%;
            transition: width 0.3s;
        }
        .result {
            background: #d4edda;
            padding: 20px;
            border-radius: 10px;
            margin-top: 20px;
            display: none;
        }
        .quality-options {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(120px, 1fr));
            gap: 10px;
            margin: 20px 0;
        }
        .quality-option {
            background: #f8f9fa;
            padding: 10px;
            border-radius: 8px;
            text-align: center;
            cursor: pointer;
            border: 2px solid transparent;
        }
        .quality-option.selected {
            border-color: #4361ee;
            background: #e3f2fd;
        }
        .stats {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 15px;
            margin: 30px 0;
        }
        .stat-card {
            background: white;
            padding: 20px;
            border-radius: 10px;
            box-shadow: 0 5px 15px rgba(0,0,0,0.1);
            text-align: center;
        }
        .stat-number {
            font-size: 2rem;
            font-weight: bold;
            color: #4361ee;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>🎬 HLS Video Converter</h1>
        
        <!-- System Stats -->
        <div class="stats">
            <div class="stat-card">
                <div class="stat-number" id="cpuUsage">--</div>
                <div>CPU Usage</div>
            </div>
            <div class="stat-card">
                <div class="stat-number" id="memoryUsage">--</div>
                <div>Memory</div>
            </div>
            <div class="stat-card">
                <div class="stat-number" id="conversionCount">0</div>
                <div>Conversions</div>
            </div>
            <div class="stat-card">
                <div class="stat-number" id="uptime">--</div>
                <div>Uptime</div>
            </div>
        </div>
        
        <!-- Upload Area -->
        <div class="upload-area" onclick="document.getElementById('fileInput').click()">
            <div style="font-size: 3rem;">📁</div>
            <h3>Drag & Drop Video Files Here</h3>
            <p>or click to select files</p>
            <p><small>Supports MP4, AVI, MOV, MKV (Up to 2GB)</small></p>
        </div>
        
        <input type="file" id="fileInput" accept="video/*,.mp4,.avi,.mov,.mkv" style="display:none;" onchange="handleFiles(this.files)">
        
        <!-- File List -->
        <div id="fileList" class="file-list"></div>
        
        <!-- Quality Selection -->
        <h3>Select Output Qualities:</h3>
        <div class="quality-options">
            <div class="quality-option selected" data-quality="240p" onclick="toggleQuality(this)">240p</div>
            <div class="quality-option selected" data-quality="480p" onclick="toggleQuality(this)">480p</div>
            <div class="quality-option selected" data-quality="720p" onclick="toggleQuality(this)">720p</div>
            <div class="quality-option" data-quality="1080p" onclick="toggleQuality(this)">1080p</div>
        </div>
        
        <!-- Convert Button -->
        <button class="btn" onclick="startConversion()" id="convertBtn" style="width: 100%;">
            🚀 Convert to HLS
        </button>
        
        <!-- Progress -->
        <div class="progress-container" id="progressContainer">
            <div class="progress-bar" id="progressBar"></div>
        </div>
        <div id="progressText" style="text-align: center; margin: 10px 0; display: none;"></div>
        
        <!-- Result -->
        <div class="result" id="result">
            <h3>✅ Conversion Complete!</h3>
            <div id="resultDetails"></div>
        </div>
    </div>

    <script>
        let selectedFiles = [];
        let selectedQualities = ['240p', '480p', '720p'];
        
        // Handle file selection
        function handleFiles(files) {
            for (let file of files) {
                if (file.type.startsWith('video/')) {
                    selectedFiles.push(file);
                }
            }
            updateFileList();
        }
        
        // Update file list display
        function updateFileList() {
            const container = document.getElementById('fileList');
            if (selectedFiles.length === 0) {
                container.innerHTML = '<div style="text-align:center;color:#666;">No files selected</div>';
                return;
            }
            
            let html = '';
            selectedFiles.forEach((file, index) => {
                html += `
                    <div class="file-item">
                        <div>
                            <strong>${file.name}</strong>
                            <div style="color:#666;font-size:0.9rem;">${formatBytes(file.size)}</div>
                        </div>
                        <button onclick="removeFile(${index})" style="background:#dc3545;color:white;border:none;padding:5px 10px;border-radius:5px;cursor:pointer;">
                            Remove
                        </button>
                    </div>
                `;
            });
            container.innerHTML = html;
        }
        
        // Remove file
        function removeFile(index) {
            selectedFiles.splice(index, 1);
            updateFileList();
        }
        
        // Toggle quality selection
        function toggleQuality(element) {
            element.classList.toggle('selected');
            const quality = element.dataset.quality;
            const index = selectedQualities.indexOf(quality);
            if (index > -1) {
                selectedQualities.splice(index, 1);
            } else {
                selectedQualities.push(quality);
            }
        }
        
        // Start conversion
        async function startConversion() {
            if (selectedFiles.length === 0) {
                alert('Please select files first!');
                return;
            }
            
            if (selectedQualities.length === 0) {
                alert('Please select at least one quality!');
                return;
            }
            
            const btn = document.getElementById('convertBtn');
            btn.disabled = true;
            btn.innerHTML = '⏳ Converting...';
            
            // Show progress
            document.getElementById('progressContainer').style.display = 'block';
            document.getElementById('progressText').style.display = 'block';
            document.getElementById('result').style.display = 'none';
            updateProgress(0, 'Preparing...');
            
            // Prepare form data
            const formData = new FormData();
            selectedFiles.forEach(file => {
                formData.append('files', file);
            });
            formData.append('qualities', JSON.stringify(selectedQualities));
            
            try {
                // Start conversion
                const response = await fetch('/convert', {
                    method: 'POST',
                    body: formData
                });
                
                // Check if response is OK
                if (!response.ok) {
                    throw new Error(`Server error: ${response.status}`);
                }
                
                const result = await response.json();
                
                if (result.success) {
                    updateProgress(100, 'Complete!');
                    showResult(result);
                } else {
                    throw new Error(result.error || 'Conversion failed');
                }
            } catch (error) {
                updateProgress(0, 'Error');
                alert('Error: ' + error.message);
                console.error('Conversion error:', error);
            } finally {
                btn.disabled = false;
                btn.innerHTML = '🚀 Convert to HLS';
                // Hide progress after delay
                setTimeout(() => {
                    document.getElementById('progressContainer').style.display = 'none';
                    document.getElementById('progressText').style.display = 'none';
                }, 2000);
            }
        }
        
        // Update progress
        function updateProgress(percent, text) {
            document.getElementById('progressBar').style.width = percent + '%';
            document.getElementById('progressText').textContent = `${text} (${Math.round(percent)}%)`;
        }
        
        // Show result
        function showResult(data) {
            const resultDiv = document.getElementById('result');
            const detailsDiv = document.getElementById('resultDetails');
            
            let html = `
                <p><strong>Video ID:</strong> ${data.video_id}</p>
                <p><strong>Qualities:</strong> ${data.qualities.join(', ')}</p>
                <div style="margin: 15px 0;">
                    <strong>🔗 M3U8 URL:</strong><br>
                    <input type="text" id="m3u8Url" value="${window.location.origin}${data.m3u8_url}" 
                           style="width:100%;padding:10px;margin:10px 0;border:1px solid #ddd;border-radius:5px;" 
                           readonly>
                    <button onclick="copyUrl()" style="background:#28a745;color:white;border:none;padding:10px 20px;border-radius:5px;cursor:pointer;width:100%;">
                        📋 Copy URL
                    </button>
                </div>
                <div style="display: flex; gap: 10px;">
                    <button onclick="testPlayback('${data.video_id}')" style="flex:1;background:#17a2b8;color:white;border:none;padding:10px;border-radius:5px;cursor:pointer;">
                        ▶️ Test Playback
                    </button>
                    <button onclick="downloadM3U8('${data.video_id}')" style="flex:1;background:#6c757d;color:white;border:none;padding:10px;border-radius:5px;cursor:pointer;">
                        📥 Download M3U8
                    </button>
                </div>
            `;
            
            detailsDiv.innerHTML = html;
            resultDiv.style.display = 'block';
            
            // Clear files
            selectedFiles = [];
            updateFileList();
            document.getElementById('fileInput').value = '';
            
            // Update stats
            updateSystemStats();
        }
        
        // Copy URL to clipboard
        function copyUrl() {
            const input = document.getElementById('m3u8Url');
            input.select();
            document.execCommand('copy');
            alert('✅ URL copied to clipboard!');
        }
        
        // Test playback
        function testPlayback(videoId) {
            window.open('/player/' + videoId, '_blank');
        }
        
        // Download M3U8
        function downloadM3U8(videoId) {
            window.location.href = '/hls/' + videoId + '/master.m3u8';
        }
        
        // Format bytes
        function formatBytes(bytes) {
            if (bytes === 0) return '0 Bytes';
            const k = 1024;
            const sizes = ['Bytes', 'KB', 'MB', 'GB'];
            const i = Math.floor(Math.log(bytes) / Math.log(k));
            return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i];
        }
        
        // Update system stats
        async function updateSystemStats() {
            try {
                const response = await fetch('/api/system');
                if (!response.ok) throw new Error('Failed to fetch system stats');
                
                const data = await response.json();
                
                document.getElementById('cpuUsage').textContent = data.cpu || '--';
                document.getElementById('memoryUsage').textContent = data.memory || '--';
                document.getElementById('conversionCount').textContent = data.total_conversions || '0';
                document.getElementById('uptime').textContent = data.uptime || '--';
            } catch (error) {
                console.error('Error updating stats:', error);
            }
        }
        
        // Initialize
        document.addEventListener('DOMContentLoaded', function() {
            updateSystemStats();
            setInterval(updateSystemStats, 30000);
            
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
                handleFiles(e.dataTransfer.files);
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
    <title>HLS Player</title>
    <style>
        body { margin: 0; padding: 20px; background: #000; }
        .container { max-width: 1000px; margin: 0 auto; }
        video { width: 100%; height: auto; border-radius: 10px; }
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
    <div class="container">
        <button class="back-btn" onclick="window.history.back()">← Back</button>
        <video controls autoplay>
            <source src="{m3u8_url}" type="application/x-mpegURL">
            Your browser does not support the video tag.
        </video>
    </div>
    
    <script>
        // Native HLS support check
        const video = document.querySelector('video');
        const m3u8Url = '{m3u8_url}';
        
        if (video.canPlayType('application/vnd.apple.mpegurl')) {
            // Safari and other browsers with native HLS support
            video.src = m3u8Url;
        } else if (Hls.isSupported()) {
            // Use Hls.js for other browsers
            const hls = new Hls();
            hls.loadSource(m3u8Url);
            hls.attachMedia(video);
            hls.on(Hls.Events.MANIFEST_PARSED, function() {
                video.play();
            });
        } else {
            alert('Your browser does not support HLS playback');
        }
    </script>
    
    <!-- Include Hls.js for broader compatibility -->
    <script src="https://cdn.jsdelivr.net/npm/hls.js@latest"></script>
</body>
</html>
'''

@app.route('/')
def index():
    return render_template_string(HTML)

@app.route('/convert', methods=['POST'])
def convert_video():
    try:
        # Check if files were uploaded
        if 'files' not in request.files:
            return jsonify({'success': False, 'error': 'No files uploaded'})
        
        files = request.files.getlist('files')
        if not files or files[0].filename == '':
            return jsonify({'success': False, 'error': 'No files selected'})
        
        # Get quality settings
        qualities_json = request.form.get('qualities', '["720p"]')
        try:
            qualities = json.loads(qualities_json)
        except:
            qualities = ["720p"]
        
        # Generate unique ID
        video_id = str(uuid.uuid4())[:8]
        output_dir = os.path.join(HLS_DIR, video_id)
        os.makedirs(output_dir, exist_ok=True)
        
        # Process first file only (simplified)
        file = files[0]
        filename = file.filename
        original_path = os.path.join(UPLOAD_DIR, f"{video_id}_{filename}")
        file.save(original_path)
        
        log_activity(f"Starting conversion: {filename} -> {video_id}")
        
        # Create master playlist
        master_playlist = os.path.join(output_dir, "master.m3u8")
        
        with open(master_playlist, 'w') as f:
            f.write("#EXTM3U\n")
            f.write("#EXT-X-VERSION:3\n")
            
            # Convert to different qualities
            for quality in qualities:
                if quality == '240p':
                    scale = "426:240"
                    bitrate = "400k"
                    audio_bitrate = "64k"
                    crf = "28"
                    bandwidth = "400000"
                elif quality == '480p':
                    scale = "854:480"
                    bitrate = "800k"
                    audio_bitrate = "96k"
                    crf = "26"
                    bandwidth = "800000"
                elif quality == '720p':
                    scale = "1280:720"
                    bitrate = "1500k"
                    audio_bitrate = "128k"
                    crf = "23"
                    bandwidth = "1500000"
                elif quality == '1080p':
                    scale = "1920:1080"
                    bitrate = "3000k"
                    audio_bitrate = "192k"
                    crf = "23"
                    bandwidth = "3000000"
                else:
                    continue
                
                # Create quality directory
                quality_dir = os.path.join(output_dir, quality)
                os.makedirs(quality_dir, exist_ok=True)
                
                # Create playlist file for this quality
                playlist_file = os.path.join(quality_dir, "index.m3u8")
                
                # Build FFmpeg command
                cmd = [
                    'ffmpeg', '-i', original_path,
                    '-vf', f'scale={scale}',
                    '-c:v', 'libx264',
                    '-preset', 'fast',
                    '-crf', crf,
                    '-c:a', 'aac',
                    '-b:a', audio_bitrate,
                    '-hls_time', '10',
                    '-hls_list_size', '0',
                    '-hls_segment_filename', os.path.join(quality_dir, 'segment_%03d.ts'),
                    '-f', 'hls', playlist_file
                ]
                
                # Run conversion
                try:
                    result = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
                    if result.returncode == 0:
                        f.write(f'#EXT-X-STREAM-INF:BANDWIDTH={bandwidth},RESOLUTION={scale}\n')
                        f.write(f'{quality}/index.m3u8\n')
                        log_activity(f"Quality {quality} converted successfully")
                    else:
                        log_activity(f"Error converting {quality}: {result.stderr[:100]}", "ERROR")
                except subprocess.TimeoutExpired:
                    log_activity(f"Timeout converting {quality}", "ERROR")
        
        # Clean up original file
        try:
            os.remove(original_path)
        except:
            pass
        
        # Update database
        db = load_database()
        conversion = {
            "video_id": video_id,
            "filename": filename,
            "qualities": qualities,
            "timestamp": datetime.now().isoformat(),
            "status": "success"
        }
        db["conversions"].insert(0, conversion)
        db["stats"]["total"] = db["stats"].get("total", 0) + 1
        db["stats"]["success"] = db["stats"].get("success", 0) + 1
        save_database(db)
        
        log_activity(f"Conversion completed: {video_id}")
        
        return jsonify({
            "success": True,
            "video_id": video_id,
            "qualities": qualities,
            "m3u8_url": f"/hls/{video_id}/master.m3u8",
            "player_url": f"/player/{video_id}"
        })
        
    except Exception as e:
        log_activity(f"Conversion error: {str(e)}", "ERROR")
        return jsonify({"success": False, "error": str(e)})

@app.route('/api/system')
def api_system():
    """API para informações do sistema"""
    try:
        cpu_percent = psutil.cpu_percent(interval=0.1)
        memory = psutil.virtual_memory()
        
        db = load_database()
        
        return jsonify({
            "cpu": f"{cpu_percent:.1f}%",
            "memory": f"{memory.percent:.1f}%",
            "total_conversions": db["stats"]["total"],
            "success_conversions": db["stats"]["success"],
            "failed_conversions": db["stats"]["failed"],
            "uptime": str(datetime.now() - datetime.fromtimestamp(psutil.boot_time())).split('.')[0]
        })
    except Exception as e:
        return jsonify({"error": str(e)})

@app.route('/api/conversions')
def api_conversions():
    """API para listar conversões"""
    db = load_database()
    return jsonify(db)

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
        return send_file(filepath)
    return "File not found", 404

@app.route('/health')
def health_check():
    """Health check do sistema"""
    return jsonify({
        "status": "healthy",
        "service": "hls-converter",
        "version": "1.0.0",
        "timestamp": datetime.now().isoformat()
    })

if __name__ == '__main__':
    print("🎬 HLS Converter v1.0")
    print("======================")
    print("🌐 Starting on port 5000")
    print("✅ Health check: http://localhost:5000/health")
    print("🎮 Interface: http://localhost:5000/")
    print("")
    
    app.run(host='0.0.0.0', port=5000, debug=False)
EOF

# 11. CRIAR BANCO DE DADOS INICIAL
echo "💾 Criando banco de dados inicial..."
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

# 12. CRIAR SERVIÇO SYSTEMD (agora como usuário)
echo "⚙️ Configurando serviço systemd..."

cat > "$HLS_HOME/hls-converter.service" << EOF
[Unit]
Description=HLS Converter Service
After=network.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$HLS_HOME
Environment=PATH=$HLS_HOME/venv/bin
ExecStart=$HLS_HOME/venv/bin/python3 $HLS_HOME/app.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# 13. INSTALAR O SERVIÇO
echo "📦 Instalando serviço systemd..."
sudo cp "$HLS_HOME/hls-converter.service" /etc/systemd/system/
sudo systemctl daemon-reload

# 14. CONFIGURAR PERMISSÕES
echo "🔐 Configurando permissões..."
chmod 755 "$HLS_HOME"
chmod 644 "$HLS_HOME"/*.py
chmod 644 "$HLS_HOME/db"/*.json
chmod -R 755 "$HLS_HOME/uploads"
chmod -R 755 "$HLS_HOME/hls"

# 15. CRIAR SCRIPT DE GERENCIAMENTO SIMPLES
echo "📝 Criando script de gerenciamento..."

cat > "$HOME/hlsctl" << 'EOF'
#!/bin/bash

case "$1" in
    start)
        sudo systemctl start hls-converter
        echo "✅ Service started"
        ;;
    stop)
        sudo systemctl stop hls-converter
        echo "✅ Service stopped"
        ;;
    restart)
        sudo systemctl restart hls-converter
        echo "✅ Service restarted"
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
        echo "🧪 Testing system..."
        curl -s http://localhost:5000/health
        echo ""
        ;;
    cleanup)
        echo "🧹 Cleaning old files..."
        find "$HOME/hls-converter/uploads" -type f -mtime +7 -delete 2>/dev/null
        find "$HOME/hls-converter/hls" -type d -mtime +7 -exec rm -rf {} \; 2>/dev/null
        echo "✅ Old files removed"
        ;;
    info)
        IP=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "localhost")
        echo "=== HLS Converter ==="
        echo "Port: 5000"
        echo "URL: http://$IP:5000"
        echo "Directory: $HOME/hls-converter"
        echo ""
        echo "Commands:"
        echo "  hlsctl start     - Start service"
        echo "  hlsctl stop      - Stop service"
        echo "  hlsctl restart   - Restart service"
        echo "  hlsctl status    - Check status"
        echo "  hlsctl logs      - View logs"
        echo "  hlsctl test      - Test system"
        echo "  hlsctl cleanup   - Clean old files"
        ;;
    *)
        echo "Usage: hlsctl [command]"
        echo ""
        echo "Commands:"
        echo "  start     - Start service"
        echo "  stop      - Stop service"
        echo "  restart   - Restart service"
        echo "  status    - Check status"
        echo "  logs      - View logs"
        echo "  test      - Test system"
        echo "  cleanup   - Clean old files"
        echo "  info      - System information"
        ;;
esac
EOF

chmod +x "$HOME/hlsctl"

# 16. INICIAR SERVIÇO
echo "🚀 Starting service..."
sudo systemctl enable hls-converter.service
sudo systemctl start hls-converter.service

sleep 5

# 17. VERIFICAR INSTALAÇÃO
echo "🔍 Verifying installation..."

if sudo systemctl is-active --quiet hls-converter.service; then
    echo "✅ Service is active!"
    
    echo "Testing application..."
    sleep 3
    
    if curl -s http://localhost:5000/health | grep -q "healthy"; then
        echo "✅✅✅ SYSTEM WORKING PERFECTLY!"
        
        echo "Testing web interface..."
        curl -s -I http://localhost:5000/ | head -1 | grep -q "200" && echo "✅ Web interface OK"
        
    else
        echo "⚠️ Health check not responding"
        echo "Checking logs..."
        sudo journalctl -u hls-converter -n 10 --no-pager
    fi
else
    echo "❌ Service failed to start"
    echo "📋 ERROR LOGS:"
    sudo journalctl -u hls-converter -n 20 --no-pager
    echo ""
    echo "🔄 Trying manual start..."
    cd "$HLS_HOME"
    ./venv/bin/python3 app.py &
    sleep 5
    curl -s http://localhost:5000/health && echo "✅ Works manually!"
fi

# 18. OBTER INFORMAÇÕES DO SISTEMA
IP=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "localhost")

echo ""
echo "🎉🎉🎉 INSTALLATION COMPLETE! 🎉🎉🎉"
echo "=================================="
echo ""
echo "✅ SYSTEM INSTALLED SUCCESSFULLY"
echo ""
echo "🌐 ACCESS URLS:"
echo "   🎨 WEB INTERFACE: http://$IP:5000"
echo "   🩺 HEALTH CHECK: http://$IP:5000/health"
echo ""
echo "⚙️  MANAGEMENT COMMANDS:"
echo "   • $HOME/hlsctl start      - Start service"
echo "   • $HOME/hlsctl stop       - Stop service"
echo "   • $HOME/hlsctl restart    - Restart service"
echo "   • $HOME/hlsctl status     - Check status"
echo "   • $HOME/hlsctl logs       - View logs"
echo "   • $HOME/hlsctl test       - Test system"
echo "   • $HOME/hlsctl cleanup    - Clean old files"
echo ""
echo "📁 SYSTEM DIRECTORIES:"
echo "   • Application: $HOME/hls-converter/"
echo "   • Uploads: $HOME/hls-converter/uploads/"
echo "   • HLS: $HOME/hls-converter/hls/"
echo "   • Logs: $HOME/hls-converter/logs/"
echo "   • Database: $HOME/hls-converter/db/"
echo ""
echo "🔄 Quick start:"
echo "   cd $HOME/hls-converter"
echo "   source venv/bin/activate"
echo "   python3 app.py"
echo ""
echo "📌 Note: All files are in your home directory with proper permissions!"
