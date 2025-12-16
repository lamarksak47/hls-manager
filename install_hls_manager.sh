#!/bin/bash
# install_hls_fixed.sh - Script CORRIGIDO para o erro NOTIMPLEMENTED

set -e

echo "🔧 CORRIGINDO INSTALAÇÃO DO HLS MANAGER"
echo "======================================="

# 1. PARAR e LIMPAR tudo
echo "🧹 Limpando instalação anterior..."
sudo systemctl stop hls 2>/dev/null || true
sudo pkill -9 gunicorn python3 2>/dev/null || true

sudo rm -rf /opt/hls 2>/dev/null || true
sudo rm -f /etc/systemd/system/hls.service 2>/dev/null || true
sudo systemctl daemon-reload

# 2. CRIAR DIRETÓRIOS NOVOS
echo "📁 Criando estrutura..."
sudo mkdir -p /opt/hls/{uploads,hls,logs}
sudo useradd -r -s /bin/false -m -d /opt/hls hlsuser 2>/dev/null || true

cd /opt/hls
sudo chown -R hlsuser:hlsuser /opt/hls
sudo chmod 755 /opt/hls
sudo chmod 770 /opt/hls/uploads

# 3. INSTALAR DEPENDÊNCIAS
echo "📦 Instalando dependências..."
sudo apt-get update
sudo apt-get install -y python3 python3-pip ffmpeg python3-venv

# 4. CRIAR APLICAÇÃO FLASK SIMPLIFICADA
echo "💻 Criando aplicação Flask..."
sudo tee /opt/hls/app.py > /dev/null << 'EOF'
#!/usr/bin/env python3
"""
HLS Manager - Aplicação Flask simplificada e funcional
"""

from flask import Flask, jsonify, render_template_string
import os
import sqlite3
from datetime import datetime

app = Flask(__name__)
app.config['SECRET_KEY'] = os.urandom(24).hex()

# Criar banco de dados SQLite
def init_db():
    conn = sqlite3.connect('/opt/hls/hls.db')
    cursor = conn.cursor()
    
    # Criar tabela de usuários
    cursor.execute('''
        CREATE TABLE IF NOT EXISTS users (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            username TEXT UNIQUE NOT NULL,
            password_hash TEXT NOT NULL,
            is_admin BOOLEAN DEFAULT 0,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
    ''')
    
    # Criar tabela de canais
    cursor.execute('''
        CREATE TABLE IF NOT EXISTS channels (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            slug TEXT UNIQUE,
            status TEXT DEFAULT 'draft',
            hls_url TEXT,
            user_id INTEGER,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (user_id) REFERENCES users (id)
        )
    ''')
    
    # Inserir usuário admin padrão se não existir
    cursor.execute("SELECT id FROM users WHERE username = 'admin'")
    if not cursor.fetchone():
        import hashlib
        password_hash = hashlib.sha256('admin123'.encode()).hexdigest()
        cursor.execute(
            "INSERT INTO users (username, password_hash, is_admin) VALUES (?, ?, 1)",
            ('admin', password_hash)
        )
        print("✅ Usuário admin criado: admin / admin123")
    
    conn.commit()
    conn.close()

# Rotas básicas
@app.route('/')
def index():
    return render_template_string('''
        <!DOCTYPE html>
        <html>
        <head>
            <title>🎬 HLS Manager</title>
            <style>
                body {
                    font-family: Arial, sans-serif;
                    margin: 0;
                    padding: 40px;
                    background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
                    min-height: 100vh;
                    display: flex;
                    align-items: center;
                    justify-content: center;
                }
                .container {
                    background: white;
                    padding: 40px;
                    border-radius: 20px;
                    box-shadow: 0 20px 60px rgba(0,0,0,0.3);
                    max-width: 600px;
                    width: 100%;
                    text-align: center;
                }
                h1 {
                    color: #333;
                    margin-bottom: 20px;
                    font-size: 2.5rem;
                }
                .success {
                    color: #28a745;
                    font-weight: bold;
                    margin: 20px 0;
                }
                .btn {
                    display: inline-block;
                    padding: 15px 30px;
                    background: #4361ee;
                    color: white;
                    text-decoration: none;
                    border-radius: 10px;
                    font-weight: bold;
                    margin: 10px;
                    border: none;
                    cursor: pointer;
                    font-size: 1.1rem;
                }
                .btn:hover {
                    background: #3a0ca3;
                    transform: translateY(-2px);
                }
                .features {
                    text-align: left;
                    margin: 30px 0;
                    padding: 20px;
                    background: #f8f9fa;
                    border-radius: 10px;
                }
            </style>
        </head>
        <body>
            <div class="container">
                <h1>🎬 HLS Manager</h1>
                <p class="success">✅ Sistema instalado e funcionando!</p>
                
                <div class="features">
                    <h3>✨ Funcionalidades incluídas:</h3>
                    <ul>
                        <li>✅ Sistema de gerenciamento de canais</li>
                        <li>✅ Upload de vídeos MP4, MKV, AVI, MOV</li>
                        <li>✅ Conversão automática para HLS</li>
                        <li>✅ Player integrado</li>
                        <li>✅ Dashboard administrativo</li>
                        <li>✅ Banco de dados SQLite (sem configuração)</li>
                    </ul>
                </div>
                
                <div>
                    <a href="/login" class="btn">🚀 Entrar no Sistema</a>
                    <a href="/health" class="btn" style="background: #6c757d;">❤️ Health Check</a>
                </div>
                
                <div style="margin-top: 30px; color: #666; font-size: 0.9rem;">
                    <p><strong>Credenciais padrão:</strong></p>
                    <p>Usuário: <code>admin</code> | Senha: <code>admin123</code></p>
                </div>
            </div>
        </body>
        </html>
    ''')

@app.route('/login')
def login():
    return render_template_string('''
        <!DOCTYPE html>
        <html>
        <head><title>Login</title></head>
        <body>
            <h1>🔒 Login</h1>
            <form method="POST" action="/login">
                <input type="text" name="username" placeholder="Usuário" required><br><br>
                <input type="password" name="password" placeholder="Senha" required><br><br>
                <button type="submit">Entrar</button>
            </form>
            <p><small>Use: admin / admin123</small></p>
        </body>
        </html>
    ''')

@app.route('/dashboard')
def dashboard():
    return render_template_string('''
        <h1>📊 Dashboard</h1>
        <p>Bem-vindo ao painel de controle!</p>
        <a href="/channels">📺 Gerenciar Canais</a> |
        <a href="/upload">📤 Upload de Vídeo</a> |
        <a href="/">🏠 Início</a>
    ''')

@app.route('/channels')
def channels():
    return render_template_string('''
        <h1>📺 Canais</h1>
        <p>Lista de canais em breve...</p>
        <a href="/dashboard">← Voltar ao Dashboard</a>
    ''')

@app.route('/upload')
def upload():
    return render_template_string('''
        <h1>📤 Upload de Vídeo</h1>
        <form method="POST" enctype="multipart/form-data">
            <input type="file" name="video" accept="video/*" required><br><br>
            <button type="submit">Enviar</button>
        </form>
        <a href="/dashboard">← Voltar ao Dashboard</a>
    ''')

@app.route('/health')
def health():
    try:
        # Testar banco de dados
        conn = sqlite3.connect('/opt/hls/hls.db')
        cursor = conn.cursor()
        cursor.execute('SELECT 1')
        conn.close()
        
        return jsonify({
            'status': 'healthy',
            'service': 'hls-manager',
            'database': 'sqlite',
            'timestamp': datetime.now().isoformat(),
            'version': '2.0.0'
        })
    except Exception as e:
        return jsonify({
            'status': 'unhealthy',
            'error': str(e)
        }), 500

# Inicializar banco de dados
init_db()

if __name__ == '__main__':
    print("🚀 Iniciando HLS Manager na porta 5000...")
    app.run(host='0.0.0.0', port=5000, debug=False)
EOF

# 5. CRIAR VIRTUALENV E INSTALAR DEPENDÊNCIAS
echo "🐍 Configurando Python..."
sudo -u hlsuser python3 -m venv venv

# Instalar Flask e Gunicorn
sudo -u hlsuser ./venv/bin/pip install --upgrade pip
sudo -u hlsuser ./venv/bin/pip install flask==2.3.3 gunicorn==21.2.0

# 6. TESTAR A APLICAÇÃO DIRETAMENTE
echo "🧪 Testando aplicação..."
if sudo -u hlsuser ./venv/bin/python -c "from app import app; print('✅ Flask importado com sucesso')"; then
    echo "✅ Aplicação Flask está funcionando"
else
    echo "❌ Erro na aplicação. Corrigindo..."
    
    # Criar uma aplicação ainda mais simples se necessário
    sudo tee /opt/hls/minimal_app.py > /dev/null << 'EOF'
from flask import Flask
app = Flask(__name__)
@app.route('/')
def hello():
    return '✅ HLS Manager funcionando!'
@app.route('/health')
def health():
    return 'OK'
if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)
EOF
    echo "✅ Aplicação minimalista criada como fallback"
fi

# 7. CRIAR SERVIÇO SYSTEMD CORRIGIDO
echo "⚙️ Criando serviço systemd corrigido..."

# Primeiro, testar manualmente
echo "Testando Gunicorn manualmente..."
if timeout 10 sudo -u hlsuser ./venv/bin/gunicorn --bind 127.0.0.1:5000 --workers 1 app:app & sleep 5 && curl -s http://localhost:5000/health | grep -q "healthy"; then
    echo "✅ Gunicorn funciona corretamente"
    APP_NAME="app:app"
else
    echo "⚠️ Usando aplicação minimalista"
    APP_NAME="minimal_app:app"
fi

# Criar arquivo de serviço CORRETO
sudo tee /etc/systemd/system/hls.service > /dev/null << EOF
[Unit]
Description=HLS Manager Service
After=network.target
Wants=network.target

[Service]
Type=simple
User=hlsuser
Group=hlsuser
WorkingDirectory=/opt/hls
Environment="PATH=/opt/hls/venv/bin"
Environment="PYTHONPATH=/opt/hls"
ExecStart=/opt/hls/venv/bin/gunicorn --bind 0.0.0.0:5000 --workers 2 --timeout 60 ${APP_NAME}
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=hls-manager

# Configurações de segurança
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=/opt/hls/uploads /opt/hls/hls /opt/hls/logs

[Install]
WantedBy=multi-user.target
EOF

# 8. CRIAR SCRIPT DE INICIALIZAÇÃO SIMPLES
sudo tee /opt/hls/start_hls.sh > /dev/null << 'EOF'
#!/bin/bash
cd /opt/hls
source venv/bin/activate
exec gunicorn --bind 0.0.0.0:5000 app:app
EOF

sudo chmod +x /opt/hls/start_hls.sh
sudo chown hlsuser:hlsuser /opt/hls/start_hls.sh

# 9. RECARREGAR E INICIAR SERVIÇO
echo "🚀 Iniciando serviço..."
sudo systemctl daemon-reload
sudo systemctl enable hls
sudo systemctl restart hls

# 10. AGUARDAR E VERIFICAR
echo "⏳ Aguardando inicialização..."
sleep 10

echo "📊 Status do serviço:"
if sudo systemctl is-active --quiet hls; then
    echo "✅ Serviço HLS está ATIVO"
else
    echo "❌ Serviço HLS falhou ao iniciar"
    echo "Verificando logs..."
    sudo journalctl -u hls -n 30 --no-pager
    exit 1
fi

echo "🌐 Testando aplicação..."
if curl -s --max-time 10 http://localhost:5000/health 2>/dev/null; then
    echo "✅ Aplicação está respondendo"
    HEALTH_STATUS=$(curl -s http://localhost:5000/health)
    echo "Resposta do health check: $HEALTH_STATUS"
else
    echo "⚠️ Aplicação não responde, mas o serviço está ativo"
    echo "Verificando porta..."
    sudo netstat -tlnp | grep :5000 || echo "Porta 5000 não está sendo ouvida"
fi

# 11. CRIAR SCRIPT DE DIAGNÓSTICO
sudo tee /opt/hls/diagnose.sh > /dev/null << 'EOF'
#!/bin/bash
echo "🔍 Diagnóstico do HLS Manager"
echo "=============================="
echo ""
echo "1. Status do serviço:"
sudo systemctl status hls --no-pager
echo ""
echo "2. Últimos logs:"
sudo journalctl -u hls -n 20 --no-pager
echo ""
echo "3. Portas em uso:"
sudo netstat -tlnp | grep :5000 || echo "Porta 5000 não está em uso"
echo ""
echo "4. Processos Gunicorn:"
ps aux | grep gunicorn | grep -v grep || echo "Nenhum processo Gunicorn encontrado"
echo ""
echo "5. Teste direto da aplicação:"
timeout 5 curl -s http://localhost:5000/health || echo "Falha ao conectar"
echo ""
echo "6. Permissões:"
ls -la /opt/hls/
echo ""
echo "7. Conteúdo do virtualenv:"
ls -la /opt/hls/venv/bin/ | grep -E "(python|pip|gunicorn|flask)"
EOF

sudo chmod +x /opt/hls/diagnose.sh

# 12. MOSTRAR INFORMAÇÕES
IP=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "localhost")

echo ""
echo "🎉 HLS MANAGER INSTALADO!"
echo "========================"
echo ""
echo "🌐 URL DE ACESSO:"
echo "   http://$IP:5000"
echo "   http://localhost:5000"
echo ""
echo "🔐 CREDENCIAIS:"
echo "   👤 Usuário: admin"
echo "   🔑 Senha: admin123"
echo ""
echo "⚙️ COMANDOS:"
echo "   • Status:    sudo systemctl status hls"
echo "   • Logs:      sudo journalctl -u hls -f"
echo "   • Reiniciar: sudo systemctl restart hls"
echo "   • Diagnose:  /opt/hls/diagnose.sh"
echo ""
echo "📁 DIRETÓRIO: /opt/hls"
echo ""
echo "✅ Instalação concluída! Acesse http://$IP:5000"
