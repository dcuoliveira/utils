cd ~/.ssh
ssh-keygen -t rsa -b 4096 -C "dan.cunhaa@gmail.com"
cat ~/.ssh/id_rsa.pub
ssh -T git@github.com

# https://github.com/settings/keys + add ssh key
# cd to local github repo
# git remote set-url origin git@github.com:username/repo-name.git
# try pull/push
