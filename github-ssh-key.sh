cd ~/.ssh
ssh-keygen -t rsa -b 4096 -C "dan.cunhaa@gmail.com"
cat ~/.ssh/id_rsa.pub
ssh -T git@github.com
