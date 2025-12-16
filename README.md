🚀 Instalação Passo a Passo
Passo 1: Preparar o Sistema
Acesse seu servidor via SSH:

bash
ssh usuario@seu-servidor-ip
Atualize o sistema:

bash
sudo apt update && sudo apt upgrade -y
Instale o Git (para baixar o script):

bash
sudo apt install git -y
Passo 2: Baixar o Script de Instalação
Opção A: Baixar do GitHub (recomendado):

bash
git clone https://github.com/seu-usuario/hls-manager.git
cd hls-manager
Opção B: Criar manualmente (se não tiver Git):

bash
nano install_hls_manager.sh
Cole o script completo que forneci anteriormente, salve (Ctrl+O, Enter) e saia (Ctrl+X).

Torne o script executável:

bash
chmod +x install_hls_manager.sh
Passo 3: Executar a Instalação
bash
sudo ./install_hls_manager.sh
O script irá:

✅ Atualizar o sistema

✅ Instalar todas dependências

✅ Configurar MariaDB

✅ Criar usuários e diretórios

✅ Instalar Python e bibliotecas

✅ Configurar Nginx

✅ Configurar firewall

✅ Inicializar banco de dados

✅ Iniciar serviços

Passo 4: Acompanhar a Instalação
Durante a instalação, você verá mensagens como:

text
🔒 INSTALANDO HLS MANAGER COMPLETO
📦 Atualizando sistema...
🗄️ Configurando MariaDB...
👤 Criando usuário dedicado...
🐍 Criando ambiente virtual...
💻 Criando aplicação Flask completa...
🌐 Configurando Nginx...
🚀 Iniciando serviços...
Atenção: Anote as credenciais que aparecerem durante a instalação!

🔑 Credenciais Geradas Automaticamente
No final da instalação, você verá algo assim:

text
🎉 HLS MANAGER INSTALADO COM SUCESSO!

🔐 INFORMAÇÕES DE ACESSO:
• URL: http://192.168.1.100
• Usuário: admin
• Senha: Kp9#mX2!qR8@zT5$

📊 BANCO DE DADOS:
• Host: localhost
• Banco: hls_manager
• Usuário: hls_manager
• Senha: HlsAppSecure@2024
IMPORTANTE: Anote essas senhas em um local seguro!

🌐 Acessar o Sistema
Abra seu navegador e acesse:

text
http://SEU-IP-DO-SERVIDOR
Faça login com:

Usuário: admin

Senha: A senha que foi gerada durante a instalação

Dashboard inicial:
https://via.placeholder.com/800x400.png?text=Dashboard+HLS+Manager

📱 Primeiros Passos no Sistema
1. Criar seu Primeiro Canal
Clique em "Novo Canal" no menu lateral

Preencha:

Nome do Canal: Ex: "Meu Canal de Vídeos"

Descrição: Ex: "Canal com meus vídeos pessoais"

Duração do Segmento: 10 segundos (padrão)

Clique em "Criar Canal"

2. Upload de Vídeos
Após criar o canal, você será redirecionado para a página de upload

Clique em "Escolher Arquivos" ou arraste os vídeos

Selecione seus arquivos MP4, MKV, AVI, etc.

Clique em "Enviar Arquivos"

3. Conversão Automática
O sistema automaticamente começará a converter para HLS

Você pode acompanhar o progresso na página do canal

Quando concluído, o status mudará para "Ativo"

4. Reproduzir o Canal
Vá para a lista de canais

Clique no nome do canal

Na página de detalhes, clique em "Reproduzir"

O player HLS abrirá e começará a stream

⚙️ Configurações Importantes
Aumentar Limite de Upload
Para arquivos maiores que 2GB:

Edite o arquivo de configuração:

bash
sudo nano /opt/hls-manager/config/.env
Altere a linha:

bash
MAX_UPLOAD_SIZE=2147483648  # 2GB
Para:

bash
MAX_UPLOAD_SIZE=5368709120  # 5GB
Reinicie o serviço:

bash
sudo systemctl restart hls-manager
Configurar Domínio Próprio
Configure DNS:

No seu registro de domínio, aponte para o IP do servidor

Configurar Nginx:

bash
sudo nano /etc/nginx/sites-available/hls-manager
Altere:

nginx
server_name _;
Para:

nginx
server_name seusite.com www.seusite.com;
Reinicie Nginx:

bash
sudo systemctl restart nginx
Habilitar SSL (HTTPS) com Let's Encrypt
bash
# Instalar Certbot
sudo apt install certbot python3-certbot-nginx -y

# Obter certificado SSL
sudo certbot --nginx -d seusite.com -d www.seusite.com

# Renovar automaticamente
sudo certbot renew --dry-run
🔧 Comandos Úteis para Administração
Monitorar Serviços
bash
# Ver status de todos serviços
sudo systemctl status hls-manager mariadb nginx

# Ver logs em tempo real
sudo journalctl -u hls-manager -f

# Ver logs da aplicação
tail -f /opt/hls-manager/logs/hls-manager.log
Gerenciar Serviços
bash
# Reiniciar HLS Manager
sudo systemctl restart hls-manager

# Reiniciar MariaDB
sudo systemctl restart mariadb

# Reiniciar Nginx
sudo systemctl restart nginx

# Verificar todos serviços
sudo systemctl list-units | grep -E "(hls|mariadb|nginx)"
Backup Manual
bash
# Executar backup
sudo -u hlsmanager /opt/hls-manager/scripts/backup.sh

# Listar backups
ls -la /opt/hls-manager/backups/
Acessar Banco de Dados
bash
mysql -u hls_manager -p hls_manager
# Senha: HlsAppSecure@2024 (ou a que foi gerada)
🐛 Solução de Problemas Comuns
Problema 1: Não consigo acessar a interface web
bash
# Verificar firewall
sudo ufw status

# Verificar se serviços estão rodando
sudo systemctl status hls-manager nginx

# Verificar portas
sudo netstat -tlnp | grep -E "(80|5000)"

# Se necessário, abrir porta
sudo ufw allow 80/tcp
Problema 2: Upload de arquivo falha
bash
# Verificar permissões
ls -la /opt/hls-manager/uploads/

# Verificar espaço em disco
df -h /opt/hls-manager

# Verificar logs
tail -f /opt/hls-manager/logs/hls-manager.log
Problema 3: Conversão HLS falha
bash
# Verificar se FFmpeg está instalado
ffmpeg -version

# Verificar espaço em disco
df -h /opt/hls-manager/hls

# Verificar logs específicos
grep -i "error" /opt/hls-manager/logs/hls-manager.log
Problema 4: Banco de dados não conecta
bash
# Verificar MariaDB
sudo systemctl status mariadb

# Testar conexão
mysql -u hls_manager -p -e "SELECT 1" hls_manager

# Verificar credenciais no .env
sudo cat /opt/hls-manager/config/.env | grep DB_
📊 Monitoramento e Manutenção
Verificar Uso de Recursos
bash
# Uso de CPU/Memória
htop

# Espaço em disco
df -h

# Logs do sistema
dmesg | tail -20
Limpeza Automática
O sistema já tem:

✅ Limpeza de arquivos temporários

✅ Rotação de logs

✅ Backup automático

✅ Monitoramento automático

Para limpeza manual:

bash
# Limpar arquivos antigos (mais de 30 dias)
find /opt/hls-manager/hls -type f -mtime +30 -delete
🔄 Atualização do Sistema
Para atualizar no futuro:

Backup primeiro:

bash
sudo -u hlsmanager /opt/hls-manager/scripts/backup.sh
Parar serviços:

bash
sudo systemctl stop hls-manager
Atualizar código:

bash
cd /opt/hls-manager
git pull origin main
Atualizar dependências:

bash
sudo -u hlsmanager ./venv/bin/pip install -r requirements.txt
Atualizar banco:

bash
sudo -u hlsmanager ./venv/bin/flask db upgrade
Reiniciar:

bash
sudo systemctl start hls-manager
📱 API de Integração
O sistema possui API REST para integração:

bash
# Listar canais (requer autenticação)
curl -X GET http://seu-ip/api/channels \
  -H "Authorization: Bearer TOKEN"

# Obter status do sistema
curl http://seu-ip/api/system/stats

# Health check
curl http://seu-ip/api/health
🎯 Exemplos de Uso
Cenário 1: Plataforma de Cursos Online
Crie canais para cada curso

Upload das videoaulas

Compartilhe links HLS com alunos

Controle acesso por usuários

Cenário 2: Streaming Pessoal
Crie canais por categoria (filmes, séries, etc.)

Converta sua biblioteca para HLS

Acesse de qualquer dispositivo

Compartilhe com família

Cenário 3: Empresa/Educação
Canais para treinamentos

Streaming de eventos

Biblioteca de vídeos institucionais

Controle de acesso por departamentos

⚠️ Dicas de Segurança
Altere a senha admin após primeiro login

Configure HTTPS para produção

Use firewall para limitar acesso

Monitore logs regularmente

Faça backups frequentes

Mantenha o sistema atualizado

📞 Suporte
Canais de Ajuda:
Logs do Sistema: /opt/hls-manager/logs/

Documentação: Interface web tem ajuda integrada

Console MariaDB: mysql -u hls_manager -p

Comandos de Diagnóstico:
bash
# Verificar saúde completa do sistema
/opt/hls-manager/scripts/monitor.sh

# Verificar todos logs recentes
sudo journalctl -u hls-manager --since "1 hour ago"

# Testar conexões
curl -I http://localhost:5000/api/health
🏁 Próximos Passos Após Instalação
✅ Login com credenciais fornecidas

✅ Alterar senha do admin

✅ Criar primeiro canal de teste

✅ Upload de vídeo pequeno para teste

✅ Verificar conversão HLS

✅ Testar player em diferentes dispositivos

✅ Configurar domínio próprio (opcional)

✅ Configurar HTTPS com SSL

🎉 Parabéns!
Seu HLS Manager está instalado e pronto para uso! Você agora tem:

✓ Sistema completo de gerenciamento de canais
✓ Conversão automática para HLS
✓ Painel web moderno
✓ Banco de dados robusto
✓ Tudo configurado para produção

Agora é só começar a criar seus canais e fazer streaming!

