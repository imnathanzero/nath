#!/usr/bin/env bash

set -e

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${CYAN}===========================================${NC}"
echo -e "${CYAN}        nxupl Auto-Installer               ${NC}"
echo -e "${CYAN}===========================================${NC}"

# 1. Argument Parsing
SKIP_SUDO=0
for arg in "$@"; do
    if [ "$arg" == "--skip-sudo" ]; then
        SKIP_SUDO=1
    fi
done

# 2. Identity & Environment Setup
REAL_USER=${SUDO_USER:-$USER}
if [ -z "$REAL_USER" ]; then REAL_USER=$(whoami); fi
USER_HOME=$(eval echo ~$REAL_USER)

IS_ROOT=0
if [ "$(id -u)" -eq 0 ]; then IS_ROOT=1; fi

HAS_SUDO=0
if command -v sudo >/dev/null 2>&1; then HAS_SUDO=1; fi

# Override privileges if flag is passed
if [ $SKIP_SUDO -eq 1 ]; then
    echo -e "${YELLOW}[*] --skip-sudo flag passed. Forcing unprivileged Rootless Mode...${NC}"
    IS_ROOT=0
    HAS_SUDO=0
fi

run_as_user() {
    if [ $IS_ROOT -eq 1 ] && [ -n "$SUDO_USER" ]; then
        sudo -u "$REAL_USER" "$@"
    else
        "$@"
    fi
}

detect_os() {
    if [ -n "$TERMUX_VERSION" ] || [ -d "/data/data/com.termux" ]; then
        echo "termux"
    elif [ "$(uname -s)" = "Darwin" ]; then
        echo "macos"
    elif [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "$ID"
    else
        echo "unknown"
    fi
}
OS=$(detect_os)

# 3. Package Management & Target Directories
if [ "$OS" = "termux" ]; then
    echo -e "${CYAN}[*] Detected Environment:${NC} Termux"
    BIN_DIR="$PREFIX/bin"
    PYTHON_BIN="python"
    
    if [ $SKIP_SUDO -eq 0 ]; then
        echo -e "${CYAN}[*] Installing Termux dependencies...${NC}"
        pkg update -y && pkg install -y python python-cryptography
    fi
else
    if [ $IS_ROOT -eq 1 ] || [ $HAS_SUDO -eq 1 ]; then
        echo -e "${CYAN}[*] Admin privileges detected. Installing system dependencies...${NC}"
        BIN_DIR="/usr/local/bin"
        PYTHON_BIN="python3"
        
        SUDO_CMD=""
        if [ $IS_ROOT -eq 0 ]; then SUDO_CMD="sudo"; fi
        
        case "$OS" in
            debian|ubuntu|pop|mint|kali)
                $SUDO_CMD apt update -y
                $SUDO_CMD apt install -y python3 python3-venv python3-pip python3-cryptography
                ;;
            arch|manjaro|endeavouros)
                $SUDO_CMD pacman -Sy --noconfirm python python-cryptography python-pip
                ;;
            fedora|rhel|centos|rocky|almalinux)
                $SUDO_CMD dnf install -y python3 python3-pip python3-cryptography
                ;;
            alpine)
                $SUDO_CMD apk add python3 py3-cryptography py3-pip
                ;;
            macos)
                if ! command -v brew >/dev/null 2>&1; then
                    echo -e "${RED}[!] Homebrew is required on macOS.${NC}"
                    exit 1
                fi
                if [ $IS_ROOT -eq 1 ]; then
                    sudo -u "$REAL_USER" brew install python
                else
                    brew install python
                fi
                BIN_DIR="$USER_HOME/.local/bin"
                ;;
        esac
        
        $SUDO_CMD mkdir -p "$BIN_DIR"
    else
        echo -e "${YELLOW}[*] Rootless Mode. Bypassing system package managers...${NC}"
        BIN_DIR="$USER_HOME/.local/bin"
        PYTHON_BIN="python3"
        mkdir -p "$BIN_DIR"
    fi
fi

# 4. Virtual Environment Setup
VENV_DIR="$USER_HOME/venv"
echo -e "${CYAN}[*] Setting up virtual environment at $VENV_DIR...${NC}"
run_as_user $PYTHON_BIN -m venv "$VENV_DIR" --system-site-packages

write_sys_file() {
    if [ $IS_ROOT -eq 0 ] && [ "$BIN_DIR" = "/usr/local/bin" ]; then
        sudo tee "$1" > /dev/null
    else
        cat > "$1"
    fi
}

# 5. Deploy Main Script
SCRIPT_PATH="$BIN_DIR/nxupl.py"
echo -e "${CYAN}[*] Deploying nxupl script to $SCRIPT_PATH...${NC}"

cat << 'PYEOF' | write_sys_file "$SCRIPT_PATH"
import os
import sys
import subprocess
import json
import asyncio
import io

def ensure_dependencies():
    packages = {
        'pyrogram': 'pyrofork', 
        'tgcrypto': 'tgcrypto',
        'rich': 'rich',         
        'questionary': 'questionary',
        'requests': 'requests',
        'googleapiclient': 'google-api-python-client', 
        'google_auth_oauthlib': 'google-auth-oauthlib'
    }
    
    missing = []
    for module, pip_name in packages.items():
        try:
            __import__(module)
        except ImportError:
            missing.append(pip_name)
            
    if missing:
        print(f"Installing missing Python modules: {', '.join(missing)}...")
        pip_cmd = [sys.executable, "-m", "pip", "install", *missing, "-q"]
        
        # Ubuntu 24.04+ PEP-668 Externally Managed Bypass
        try:
            if os.path.exists('/etc/os-release'):
                with open('/etc/os-release', 'r') as f:
                    os_data = f.read()
                if 'ID=ubuntu' in os_data:
                    import re
                    v_match = re.search(r'VERSION_ID="?(\d+\.\d+)"?', os_data)
                    if v_match and float(v_match.group(1)) >= 24.04:
                        pip_cmd.append("--break-system-packages")
        except Exception:
            pass
            
        subprocess.check_call(pip_cmd)
        os.system('cls' if os.name == 'nt' else 'clear')

ensure_dependencies()

from pyrogram import Client
import questionary
import requests
from rich.console import Console
from rich.panel import Panel
from rich.text import Text
from rich.progress import Progress, TextColumn, BarColumn, DownloadColumn, TransferSpeedColumn, TimeRemainingColumn
from prompt_toolkit.key_binding import KeyBindings, merge_key_bindings

from googleapiclient.discovery import build
from googleapiclient.http import MediaFileUpload
from google.auth.transport.requests import Request
from google.oauth2.credentials import Credentials
from google_auth_oauthlib.flow import InstalledAppFlow

console = Console()

CONFIG_DIR = os.path.expanduser("~/.config/nxupl")
CONFIG_FILE = os.path.join(CONFIG_DIR, "config.json")
GDRIVE_CREDS = os.path.join(CONFIG_DIR, "gdrive_credentials.json")
GDRIVE_TOKEN = os.path.join(CONFIG_DIR, "gdrive_token.json")

# ==========================================
# TRANSLATIONS DICTIONARY
# ==========================================
LANG = "en"

TRANSLATIONS = {
    "en": {
        "target_service": "Where do you want to upload your files?",
        "change_lang": "⚙️ Change Language",
        "api_id_prompt": "API ID (input hidden):",
        "api_hash_prompt": "API HASH (input hidden):",
        "bot_token_prompt": "Bot Token (Leave blank to login as User, input hidden):",
        "chat_id_prompt": "Target Chat ID (e.g., -100123... or @channelname):",
        "press_enter": "Press Enter to open the nxupl browser...",
        "no_files": "No files selected. Exiting.",
        "files_queued": "{count} file(s) queued for {service}.",
        "thumb_prompt": "Thumbnail path (Leave blank to skip, Tab to autocomplete):",
        "caption_prompt": "Caption (Leave blank to use the filename):",
        "all_done": "All operations completed!",
        "cancelled": "Upload cancelled by user. Exiting.",
        "connecting_tg": "🔄 Connecting to Telegram...",
        "tg_connected": "🚀 Connection Established! Starting Uploads...",
        "done": "Done",
        "failed": "Failed",
        "auth_gdrive": "🔄 Authenticating with Google Drive...",
        "gdrive_connected": "🚀 Google Drive Connected! Starting Uploads...",
        "prep_http": "🚀 Preparing Uploads to {service}...",
        "api_error": "API Error",
        "browser_target": "Target: {service}",
        "browser_curr_dir": "Current Directory: {current_dir}",
        "browser_controls": "Controls: [SPACE] Select | [ENTER] Confirm | [←/→] Back/Forward",
        "browser_title": "📁 nxupl File Browser",
        "browser_finish": "✅ [ FINISH & UPLOAD SELECTION ]",
        "browser_up": "🔙 [ Go Up / .. ]",
        "browser_folders": "─── Folders ───",
        "browser_files": "─── Files ───",
        "browser_select": "Select items:",
        "gdrive_missing": "[bold red]Google Drive Credentials Missing![/bold red]\n\n1. Go to [cyan]https://console.cloud.google.com[/cyan]\n2. Create a project and enable the [bold]Google Drive API[/bold].\n3. Create OAuth 2.0 Client ID (Desktop App).\n4. Download the JSON, rename to [bold yellow]gdrive_credentials.json[/bold yellow]\n5. Place it in: [bold cyan]{config_dir}[/bold cyan]"
    },
    "id": {
        "target_service": "Ke mana Anda ingin mengunggah file?",
        "change_lang": "⚙️ Ganti Bahasa",
        "api_id_prompt": "API ID (input tersembunyi):",
        "api_hash_prompt": "API HASH (input tersembunyi):",
        "bot_token_prompt": "Bot Token (Kosongkan untuk login sebagai User, input tersembunyi):",
        "chat_id_prompt": "Target Chat ID (contoh: -100123... atau @channelname):",
        "press_enter": "Tekan Enter untuk membuka file browser nxupl...",
        "no_files": "Tidak ada file yang dipilih. Keluar.",
        "files_queued": "{count} file antre untuk {service}.",
        "thumb_prompt": "Path thumbnail (Kosongkan untuk melewati, Tab untuk autocomplete):",
        "caption_prompt": "Caption (Kosongkan untuk menggunakan nama file):",
        "all_done": "Semua operasi selesai!",
        "cancelled": "Upload dibatalkan oleh pengguna. Keluar.",
        "connecting_tg": "🔄 Menghubungkan ke Telegram...",
        "tg_connected": "🚀 Koneksi Berhasil! Memulai Upload...",
        "done": "Selesai",
        "failed": "Gagal",
        "auth_gdrive": "🔄 Mengautentikasi dengan Google Drive...",
        "gdrive_connected": "🚀 Google Drive Terhubung! Memulai Upload...",
        "prep_http": "🚀 Menyiapkan Upload ke {service}...",
        "api_error": "API Error",
        "browser_target": "Target: {service}",
        "browser_curr_dir": "Direktori Saat Ini: {current_dir}",
        "browser_controls": "Kontrol: [SPASI] Pilih | [ENTER] Konfirmasi | [←/→] Kembali/Maju",
        "browser_title": "📁 nxupl File Browser",
        "browser_finish": "✅ [ SELESAI & UPLOAD PILIHAN ]",
        "browser_up": "🔙 [ Naik / .. ]",
        "browser_folders": "─── Folder ───",
        "browser_files": "─── File ───",
        "browser_select": "Pilih item:",
        "gdrive_missing": "[bold red]Kredensial Google Drive Hilang![/bold red]\n\n1. Buka [cyan]https://console.cloud.google.com[/cyan]\n2. Buat project dan aktifkan [bold]Google Drive API[/bold].\n3. Buat OAuth 2.0 Client ID (Desktop App).\n4. Download JSON, ubah nama menjadi [bold yellow]gdrive_credentials.json[/bold yellow]\n5. Letakkan di: [bold cyan]{config_dir}[/bold cyan]"
    }
}

def t(key, **kwargs):
    text = TRANSLATIONS.get(LANG, TRANSLATIONS["en"]).get(key, TRANSLATIONS["en"].get(key, key))
    return text.format(**kwargs)

# ==========================================
# CORE FUNCTIONS
# ==========================================
def load_config():
    if os.path.exists(CONFIG_FILE):
        with open(CONFIG_FILE, 'r') as f:
            return json.load(f)
    return {}

def save_config(config):
    os.makedirs(CONFIG_DIR, exist_ok=True)
    with open(CONFIG_FILE, 'w') as f:
        json.dump(config, f, indent=4)

def censor_string(text, show_last=4):
    if not text: return ""
    text = str(text)
    if len(text) <= show_last: return "*" * len(text)
    return "*" * (len(text) - show_last) + text[-show_last:]

def clear_screen():
    os.system('cls' if os.name == 'nt' else 'clear')

def create_progress_bar():
    return Progress(
        TextColumn("[bold blue]{task.description}"),
        BarColumn(bar_width=None, complete_style="green", finished_style="bold green"),
        "[progress.percentage]{task.percentage:>3.1f}%", "•", DownloadColumn(), "•", TransferSpeedColumn(), "•", TimeRemainingColumn(),
        console=console, expand=True
    )

def interactive_file_picker(service_name):
    current_dir = os.getcwd()
    global_selected = set() 
    
    while True:
        clear_screen()
        
        header = Text(f"{t('browser_target', service=service_name)}\n{t('browser_curr_dir', current_dir=current_dir)}\n", style="bold cyan")
        header.append(t("browser_controls"), style="italic white")
        console.print(Panel(header, title=t("browser_title"), border_style="cyan"))

        try:
            entries = os.listdir(current_dir)
        except PermissionError:
            entries = []
            
        dirs = sorted([d for d in entries if os.path.isdir(os.path.join(current_dir, d))])
        files = sorted([f for f in entries if os.path.isfile(os.path.join(current_dir, f))])
        
        choices = [
            questionary.Choice(t("browser_finish"), value="DONE"),
            questionary.Choice(t("browser_up"), value="UP"),
            questionary.Separator(" ")
        ]
        
        if dirs:
            choices.append(questionary.Separator(t("browser_folders")))
            for d in dirs:
                choices.append(questionary.Choice(f"📁 {d}/", value=f"DIR:{d}"))
                
        if files:
            choices.append(questionary.Separator(t("browser_files")))
            for f in files:
                full_path = os.path.join(current_dir, f)
                choices.append(questionary.Choice(
                    f"📄 {f}", 
                    value=f"FILE:{full_path}", 
                    checked=(full_path in global_selected)
                ))
                
        prompt = questionary.checkbox(
            t("browser_select"),
            choices=choices,
            style=questionary.Style([
                ('highlighted', 'fg:cyan bold'),
                ('selected', 'fg:green'),
                ('separator', 'fg:darkgray'),
            ]),
            qmark="👉"
        )
        
        custom_kb = KeyBindings()
        
        @custom_kb.add('left')
        def go_left(event):
            event.app.exit(result=["UP"])
            
        @custom_kb.add('right')
        def go_right(event):
            try:
                ic = event.app.layout.current_control
                choice = ic.choices[ic.pointed_at]
                if choice.value and isinstance(choice.value, str) and choice.value.startswith("DIR:"):
                    event.app.exit(result=[choice.value])
            except Exception:
                pass 
                
        prompt.application.key_bindings = merge_key_bindings([
            prompt.application.key_bindings, 
            custom_kb
        ])
        
        answers = prompt.ask()
        
        if answers is None: 
            console.print(f"\n[bold red]{t('cancelled')}[/bold red]")
            sys.exit(0)
            
        current_files = {os.path.join(current_dir, f) for f in files}
        global_selected -= current_files 
        
        for ans in answers:
            if ans.startswith("FILE:"):
                global_selected.add(ans[5:])
                
        if "DONE" in answers:
            break
        elif "UP" in answers:
            current_dir = os.path.dirname(current_dir)
        else:
            nav_dirs = [ans for ans in answers if ans.startswith("DIR:")]
            if nav_dirs:
                current_dir = os.path.join(current_dir, nav_dirs[0][4:])
                
    return sorted(list(global_selected))

async def tg_progress_callback(current, total, progress, task_id):
    progress.update(task_id, completed=current, total=total)

async def upload_telegram(api_id, api_hash, bot_token, chat_id, files, thumb, caption_template):
    console.print(f"\n[bold yellow]{t('connecting_tg')}[/bold yellow]")
    app_args = {"name": "nxupl_session", "api_id": api_id, "api_hash": api_hash, "workdir": CONFIG_DIR}
    if bot_token: app_args["bot_token"] = bot_token

    app = Client(**app_args)
    progress = create_progress_bar()

    async with app:
        clear_screen()
        console.print(Panel(f"[bold green]{t('tg_connected')}[/bold green]", border_style="green"))
        with progress:
            for file in files:
                filename = os.path.basename(file)
                task_id = progress.add_task(f"Uploading {filename}", total=os.path.getsize(file))
                try:
                    await app.send_document(
                        chat_id=int(chat_id) if chat_id.lstrip('-').isdigit() else chat_id,
                        document=file, thumb=thumb, caption=(caption_template if caption_template else filename),
                        progress=tg_progress_callback, progress_args=(progress, task_id)
                    )
                    progress.update(task_id, description=f"[bold green]✅ {filename} ({t('done')})[/bold green]")
                except Exception as e:
                    progress.update(task_id, description=f"[bold red]❌ {filename} ({t('failed')})[/bold red]")
                    console.print(f"[bold red]Error on {filename}: {e}[/bold red]")

def get_gdrive_service():
    SCOPES = ['https://www.googleapis.com/auth/drive.file']
    creds = None
    
    if not os.path.exists(GDRIVE_CREDS):
        console.print(Panel(t("gdrive_missing", config_dir=CONFIG_DIR), border_style="red"))
        sys.exit(0)

    if os.path.exists(GDRIVE_TOKEN):
        creds = Credentials.from_authorized_user_file(GDRIVE_TOKEN, SCOPES)
        
    if not creds or not creds.valid:
        if creds and creds.expired and creds.refresh_token:
            creds.refresh(Request())
        else:
            flow = InstalledAppFlow.from_client_secrets_file(GDRIVE_CREDS, SCOPES)
            console.print("\n[bold yellow]Please copy the URL below into your browser to authorize:[/bold yellow]")
            creds = flow.run_local_server(port=0, open_browser=False)
        with open(GDRIVE_TOKEN, 'w') as token:
            token.write(creds.to_json())
            
    return build('drive', 'v3', credentials=creds)

def upload_gdrive(files):
    clear_screen()
    console.print(Panel(f"[bold yellow]{t('auth_gdrive')}[/bold yellow]", border_style="yellow"))
    service = get_gdrive_service()
    
    clear_screen()
    console.print(Panel(f"[bold green]{t('gdrive_connected')}[/bold green]", border_style="green"))
    progress = create_progress_bar()

    with progress:
        for file_path in files:
            filename = os.path.basename(file_path)
            file_size = os.path.getsize(file_path)
            task_id = progress.add_task(f"Uploading {filename}", total=file_size)
            
            try:
                media = MediaFileUpload(file_path, mimetype='application/octet-stream', resumable=True, chunksize=5*1024*1024)
                request = service.files().create(body={'name': filename}, media_body=media, fields='id, webViewLink')
                
                response = None
                while response is None:
                    status, response = request.next_chunk()
                    if status:
                        progress.update(task_id, completed=status.resumable_progress)
                        
                progress.update(task_id, completed=file_size)
                link = response.get('webViewLink')
                progress.update(task_id, description=f"[bold green]✅ {filename}[/bold green] [white]({link})[/white]")
                
            except Exception as e:
                progress.update(task_id, description=f"[bold red]❌ {filename} ({t('failed')})[/bold red]")
                console.print(f"\n[bold red]Error on {filename}: {e}[/bold red]")

class ProgressFileReader:
    def __init__(self, filename, progress, task_id):
        self._file = open(filename, 'rb')
        self._progress = progress
        self._task_id = task_id
        self._length = os.path.getsize(filename)
    def read(self, size=-1):
        chunk = self._file.read(size)
        self._progress.update(self._task_id, advance=len(chunk))
        return chunk
    def __getattr__(self, attr): return getattr(self._file, attr)
    def __len__(self): return self._length
    def __enter__(self): return self
    def __exit__(self, exc_type, exc_val, exc_tb): self._file.close()

def upload_http(service, files):
    clear_screen()
    console.print(Panel(f"[bold green]{t('prep_http', service=service)}[/bold green]", border_style="green"))
    progress = create_progress_bar()

    with progress:
        for file_path in files:
            filename = os.path.basename(file_path)
            file_size = os.path.getsize(file_path)
            task_id = progress.add_task(f"Uploading {filename}", total=file_size)
            
            try:
                if service == "GoFile":
                    server = requests.get("https://api.gofile.io/servers").json()["data"]["servers"][0]["name"]
                    upload_url = f"https://{server}.gofile.io/contents/upload"
                    with ProgressFileReader(file_path, progress, task_id) as f:
                        res = requests.post(upload_url, files={"file": (filename, f)}).json()
                    
                    if res.get("status") == "ok":
                        link = res["data"]["downloadPage"]
                        progress.update(task_id, description=f"[bold green]✅ {filename}[/bold green] [white]({link})[/white]")
                    else:
                        progress.update(task_id, description=f"[bold red]❌ {filename} ({t('api_error')})[/bold red]")

                elif service == "Pixeldrain":
                    upload_url = f"https://pixeldrain.com/api/file/{filename}"
                    with ProgressFileReader(file_path, progress, task_id) as f:
                        res = requests.put(upload_url, data=f).json()
                    
                    if res.get("success"):
                        link = f"https://pixeldrain.com/u/{res['id']}"
                        progress.update(task_id, description=f"[bold green]✅ {filename}[/bold green] [white]({link})[/white]")
                    else:
                        progress.update(task_id, description=f"[bold red]❌ {filename} ({t('api_error')})[/bold red]")
                        
            except Exception as e:
                progress.update(task_id, description=f"[bold red]❌ {filename} ({t('failed')})[/bold red]")
                console.print(f"\n[bold red]Error on {filename}: {e}[/bold red]")

def main():
    global LANG
    clear_screen()
    config = load_config()

    LANG = config.get("language")
    if not LANG:
        LANG = questionary.select(
            "Select Language / Pilih Bahasa:",
            choices=[
                questionary.Choice("English", value="en"), 
                questionary.Choice("Bahasa Indonesia", value="id")
            ],
            style=questionary.Style([('selected', 'fg:cyan bold')])
        ).ask()
        if not LANG: sys.exit(0)
        config["language"] = LANG
        save_config(config)

    while True:
        clear_screen()
        console.print(Panel(
            "[bold cyan]nxupl | Universal Uploader[/bold cyan]\n"
            "[white]Deploy files to Telegram, Google Drive, GoFile, or Pixeldrain.[/white]", 
            border_style="cyan"
        ))
        
        service = questionary.select(
            t("target_service"),
            choices=[
                "Telegram", "Google Drive", "GoFile", "Pixeldrain", 
                questionary.Separator(),
                questionary.Choice(t("change_lang"), value="LANG")
            ],
            style=questionary.Style([('selected', 'fg:cyan bold')])
        ).ask()
        
        if not service: sys.exit(0)
        
        if service == "LANG":
            LANG = questionary.select(
                "Select Language / Pilih Bahasa:",
                choices=[
                    questionary.Choice("English", value="en"), 
                    questionary.Choice("Bahasa Indonesia", value="id")
                ],
                style=questionary.Style([('selected', 'fg:cyan bold')])
            ).ask()
            if not LANG: sys.exit(0)
            config["language"] = LANG
            save_config(config)
            continue
            
        break

    if service == "Telegram":
        api_id = config.get("api_id") or questionary.password(t("api_id_prompt")).ask()
        if not api_id: sys.exit(0)
        
        api_hash = config.get("api_hash") or questionary.password(t("api_hash_prompt")).ask()
        bot_token = config.get("bot_token") if "bot_token" in config else questionary.password(t("bot_token_prompt")).ask()
        chat_id = config.get("chat_id") or questionary.text(t("chat_id_prompt")).ask()

        config.update({"api_id": api_id, "api_hash": api_hash, "bot_token": bot_token, "chat_id": chat_id})
        save_config(config)
        
        cred_text = (
            f"[bold]API ID:[/bold]    {censor_string(api_id)}\n"
            f"[bold]API HASH:[/bold]  {censor_string(api_hash)}\n"
            f"[bold]BOT TOKEN:[/bold] {'User Account Mode' if not bot_token else censor_string(bot_token)}\n"
            f"[bold]CHAT ID:[/bold]   {chat_id}"
        )
        console.print(Panel(cred_text, title="🔒 Telegram Credentials Loaded", border_style="green", expand=False))
        questionary.confirm(t("press_enter")).ask()

    files = interactive_file_picker(service)
    
    if not files:
        console.print(f"[bold red]{t('no_files')}[/bold red]")
        return
        
    clear_screen()
    console.print(Panel(f"[bold green]{t('files_queued', count=len(files), service=service)}[/bold green]", border_style="green"))

    if service == "Telegram":
        thumb_path = questionary.path(t("thumb_prompt")).ask()
        thumb = thumb_path if thumb_path and os.path.isfile(thumb_path) else None
        caption_template = questionary.text(t("caption_prompt")).ask()
        asyncio.run(upload_telegram(config["api_id"], config["api_hash"], config["bot_token"], config["chat_id"], files, thumb, caption_template))
    elif service == "Google Drive":
        upload_gdrive(files)
    else:
        upload_http(service, files)
        
    console.print(f"\n[bold cyan]{t('all_done')}[/bold cyan]")

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        console.print(f"\n\n[bold red]{t('cancelled')}[/bold red]")
PYEOF

# 6. Create Executable Binary Launcher
WRAPPER_PATH="$BIN_DIR/nxupl"
echo -e "${CYAN}[*] Installing global binary to $WRAPPER_PATH...${NC}"

cat << EOF | write_sys_file "$WRAPPER_PATH"
#!/usr/bin/env bash
VENV_PYTHON="$USER_HOME/venv/bin/python"
SCRIPT="$SCRIPT_PATH"

if [ ! -f "\$VENV_PYTHON" ]; then
    echo "Error: Virtual environment not found at \$VENV_PYTHON"
    exit 1
fi

exec "\$VENV_PYTHON" "\$SCRIPT" "\$@"
EOF

# Make files executable (using sudo if necessary)
if [ $IS_ROOT -eq 0 ] && [ "$BIN_DIR" = "/usr/local/bin" ]; then
    sudo chmod +x "$SCRIPT_PATH" "$WRAPPER_PATH"
else
    chmod +x "$SCRIPT_PATH" "$WRAPPER_PATH"
fi

# 7. PATH Verification Check (For Rootless Environments)
if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
    echo -e "\n${RED}[!] ATTENTION: ${NC}$BIN_DIR is NOT in your current PATH."
    echo -e "${YELLOW}To use the 'nxupl' command anywhere, run this command now:${NC}"
    echo -e "export PATH=\"$BIN_DIR:\$PATH\""
    echo -e "${YELLOW}(Add that line to your ~/.bashrc or ~/.zshrc to make it permanent)${NC}"
fi

echo -e "\n${GREEN}===========================================${NC}"
echo -e "${GREEN}   Installation Completed Successfully!   ${NC}"
echo -e "${GREEN}===========================================${NC}"
echo -e "You can now run the tool from anywhere using: ${CYAN}nxupl${NC}\n"
