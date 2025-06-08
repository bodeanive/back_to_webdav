# back_to_webdav

#   描述: 本脚本使用 tar, gpg, 和 curl 将指定目录加密打包并上传到 WebDAV。
#
#   依赖:
#       - tar: 用于打包和压缩文件。
#       - GnuPG (gpg): 用于对打包后的文件进行对称加密。
#       - curl: 用于与 WebDAV 服务器进行交互和文件上传。
#
#   使用方法:
#       1.  确保已安装 tar, gpg, curl。
#           (例如: sudo apt update && sudo apt install -y tar gpg curl)
#       2.  在你的 HOME 目录下创建一个 .netrc 文件来存放 WebDAV 凭据。
#       3.  将此脚本保存为 backup_to_webdav.sh 并赋予执行权限。
#           (chmod +x backup_to_webdav.sh)
#       4.  根据需要修改下面的 "可配置变量" 部分。
#       5.  将加密密码存储在 GPG_PASSWORD_FILE 指定的文件中。
#       6.  运行脚本: ./backup_to_webdav.sh

``` bash
touch ~/.netrc
chmod 600 ~/.netrc
```
## 向文件中添加一行，格式如下：
` machine [你的WebDAV主机名] login [你的用户名] password [你的密码] `

## 加密密码
```
mkdir -p ~/.gnupg
echo "your-super-secret-password" > ~/.gnupg/webdav_backup_pass
chmod 600 ~/.gnupg/webdav_backup_pass
```
## 解密
```
#使用 gpg 解密文件。它会提示你输入加密时使用的密码。
gpg -o codex-backup.tar.gz -d codex-backup-20250608-013000.tar.gz.gpg
```
