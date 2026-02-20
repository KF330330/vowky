#!/bin/bash
set -euo pipefail

# VowKy Analytics Deploy Script
# Usage: ./deploy.sh

SERVER="root@8.210.146.28"
REMOTE_DIR="/opt/vowky-analytics"
SERVICE_NAME="vowky-analytics"

echo "=== VowKy Analytics Deploy ==="

# 1. Upload files
echo "[1/5] Uploading files..."
ssh $SERVER "mkdir -p $REMOTE_DIR"
scp app.py dashboard.html requirements.txt $SERVER:$REMOTE_DIR/

# 2. Install dependencies
echo "[2/5] Installing Python dependencies..."
ssh $SERVER "cd $REMOTE_DIR && pip3 install -r requirements.txt -q"

# 3. Create systemd service
echo "[3/5] Configuring systemd service..."
ssh $SERVER "cat > /etc/systemd/system/${SERVICE_NAME}.service << 'UNIT'
[Unit]
Description=VowKy Analytics
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/vowky-analytics
Environment=ANALYTICS_DB=/opt/vowky-analytics/vowky_analytics.db
Environment=ANALYTICS_USER=admin
Environment=ANALYTICS_PASS=vowky-stats-2026
Environment=ANALYTICS_SALT=vowky-anon-salt-x7k
ExecStart=/usr/bin/python3 -m uvicorn app:app --host 127.0.0.1 --port 8100
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT"

ssh $SERVER "systemctl daemon-reload && systemctl enable $SERVICE_NAME && systemctl restart $SERVICE_NAME"

# 4. Configure Nginx
echo "[4/5] Configuring Nginx..."
ssh $SERVER "cat > /etc/nginx/sites-available/analytics.vowky.com << 'NGINX'
server {
    listen 80;
    server_name analytics.vowky.com;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name analytics.vowky.com;

    ssl_certificate /etc/letsencrypt/live/vowky.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/vowky.com/privkey.pem;

    # Collection endpoints - public, CORS enabled
    location = /t.gif {
        proxy_pass http://127.0.0.1:8100;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Host \$host;
        access_log off;
    }

    location = /api/event {
        proxy_pass http://127.0.0.1:8100;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Host \$host;
        proxy_set_header Content-Type \$content_type;
        access_log off;
    }

    # Dashboard and API - protected
    location / {
        proxy_pass http://127.0.0.1:8100;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Host \$host;
    }

    # Security headers
    add_header X-Frame-Options DENY always;
    add_header X-Content-Type-Options nosniff always;
}
NGINX"

ssh $SERVER "ln -sf /etc/nginx/sites-available/analytics.vowky.com /etc/nginx/sites-enabled/ && nginx -t && systemctl reload nginx"

# 5. Check SSL cert covers analytics subdomain
echo "[5/5] Checking SSL certificate..."
ssh $SERVER "certbot certificates 2>/dev/null | grep -q 'analytics.vowky.com' && echo 'SSL: OK (already covered)' || echo 'WARNING: analytics.vowky.com not in SSL cert. Run: certbot --nginx -d analytics.vowky.com'"

# Verify
echo ""
echo "=== Checking service status ==="
ssh $SERVER "systemctl is-active $SERVICE_NAME && echo 'Service: RUNNING' || echo 'Service: FAILED'"
echo ""
echo "Deploy complete!"
echo "Dashboard: https://analytics.vowky.com"
echo "Login: admin / vowky-stats-2026"
