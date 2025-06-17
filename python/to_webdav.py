import os
import zipfile
import subprocess
from datetime import datetime
from webdav3.client import Client

# --- 配置区 ---

# 1. 需要备份的文件或文件夹列表
SOURCE_ITEMS = ['/path/to/your/important_data', '/path/to/another/file.log']

# 2. WebDAV 服务器列表
WEBDAV_SERVERS = [
    {
        'url': 'https://dav.jianguoyun.com/dav/',
        'username': 'your_email@example.com',
        'password': 'your_app_password'
    }
]

# 3. 用于 OpenSSL 加密的密码 (注意：这里是字符串)
ENCRYPTION_PASSWORD = 'your-very-strong-and-secret-password'


def create_unencrypted_zip(source_items, archive_name):
    """第一步：创建一个标准的、未加密的ZIP文件。"""
    print(f"步骤 1: 正在创建标准ZIP压缩包: {archive_name}")
    try:
        with zipfile.ZipFile(archive_name, 'w', zipfile.ZIP_DEFLATED) as zf:
            for item in source_items:
                if os.path.isfile(item):
                    zf.write(item, os.path.basename(item))
                    print(f"  - 已添加文件: {item}")
                elif os.path.isdir(item):
                    for foldername, subfolders, filenames in os.walk(item):
                        for filename in filenames:
                            file_path = os.path.join(foldername, filename)
                            arcname = os.path.relpath(file_path, os.path.dirname(item))
                            zf.write(file_path, arcname)
                    print(f"  - 已添加文件夹: {item}")
        print("标准ZIP压缩包创建成功。")
        return True
    except Exception as e:
        print(f"创建ZIP压缩包时出错: {e}")
        return False

def encrypt_with_openssl(input_file, output_file, password):
    """第二步：使用OpenSSL加密文件。"""
    print(f"\n步骤 2: 正在使用OpenSSL加密文件 -> {output_file}")
    # 使用AES-256-CBC算法，-pbkdf2增加密码破解难度，-salt增加安全性
    command = [
        'openssl', 'enc', '-aes-256-cbc', '-salt', '-pbkdf2',
        '-in', input_file,
        '-out', output_file,
        '-k', password
    ]
    try:
        # 运行OpenSSL命令
        process = subprocess.run(command, check=True, capture_output=True, text=True)
        print("文件已成功通过OpenSSL加密。")
        return True
    except FileNotFoundError:
        print("错误: 'openssl' 命令未找到。请确保OpenSSL已安装并位于系统的PATH中。")
        return False
    except subprocess.CalledProcessError as e:
        print("OpenSSL加密过程中出错:")
        print(f"返回码: {e.returncode}")
        print(f"错误输出: {e.stderr}")
        return False

def upload_to_webdav(server_config, local_file, remote_dir):
    """第三步：上传加密后的文件。"""
    options = {
        'webdav_hostname': server_config['url'],
        'webdav_login': server_config['username'],
        'webdav_password': server_config['password']
    }
    client = Client(options)
    full_remote_dir = f"/{remote_dir.strip('/')}/"
    remote_path = os.path.join(full_remote_dir, os.path.basename(local_file))

    print(f"\n步骤 3: 正在上传 {local_file} 到 {server_config['url']}...")
    try:
        if not client.check(full_remote_dir):
            client.mkdir(full_remote_dir)
            print(f"  - 在服务器上创建了目录: {full_remote_dir}")

        client.upload(remote_path, local_file)
        print(f"  - 文件成功上传至: {remote_path}")
    except Exception as e:
        print(f"  - 上传失败: {e}")

def main():
    """主执行函数。"""
    timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
    remote_dir_name = datetime.now().strftime('%Y-%m')

    # 定义文件名
    zip_filename = f'backup_{timestamp}.zip'
    encrypted_filename = f'{zip_filename}.enc'

    # 执行步骤
    if not create_unencrypted_zip(SOURCE_ITEMS, zip_filename):
        return

    if not encrypt_with_openssl(zip_filename, encrypted_filename, ENCRYPTION_PASSWORD):
        # 如果加密失败，也要清理已生成的zip文件
        if os.path.exists(zip_filename):
            os.remove(zip_filename)
        return

    for server in WEBDAV_SERVERS:
        upload_to_webdav(server, encrypted_filename, remote_dir_name)

    # 最后一步：清理本地临时文件
    print("\n步骤 4: 正在清理本地临时文件...")
    try:
        if os.path.exists(zip_filename):
            os.remove(zip_filename)
            print(f"  - 已删除临时ZIP文件: {zip_filename}")
        if os.path.exists(encrypted_filename):
            os.remove(encrypted_filename)
            print(f"  - 已删除临时加密文件: {encrypted_filename}")
        print("清理完成。")
    except OSError as e:
        print(f"删除本地临时文件时出错: {e}")

if __name__ == "__main__":
    main()
