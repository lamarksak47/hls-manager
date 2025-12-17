🚀 Instalação Passo a Passo

git clone https://github.com/lamarksak47/hls-manager.git

cd hls-manager

chmod +x install_hls_manager.sh

sudo ./install_hls_manager.sh

SOLOÇÃO PARA POSSIVEL ERRO.
 
Passo 1: Verificar logs detalhados

sudo journalctl -u hls-converter -n 50 --no-pager

Passo 2: Corrigir o serviço systemd

Primeiro, pare o serviço e vamos corrigir o arquivo de serviço:



sudo systemctl stop hls-converter

Agora, vamos criar um arquivo de serviço corrigido:



sudo tee /etc/systemd/system/hls-converter.service > /dev/null << 'EOF'
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

# Usar python diretamente em vez de waitress-serve
ExecStart=/opt/hls-converter/venv/bin/python3 /opt/hls-converter/app.py

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
Passo 3: Corrigir permissões e estrutura


# Verificar se o diretório existe
ls -la /opt/hls-converter/

# Verificar se o Python está funcionando
sudo -u hlsuser /opt/hls-converter/venv/bin/python3 --version

# Verificar se o app.py existe
ls -la /opt/hls-converter/app.py

# Corrigir permissões se necessário
sudo chmod +x /opt/hls-converter/app.py
Passo 4: Testar manualmente primeiro
bash
# Testar o aplicativo manualmente
cd /opt/hls-converter
sudo -u hlsuser ./venv/bin/python3 app.py
Se funcionar manualmente, pressione Ctrl+C e continue.

Passo 5: Recarregar e iniciar serviço


sudo systemctl daemon-reload
sudo systemctl restart hls-converter
sudo systemctl status hls-converter
