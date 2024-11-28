# Download Python source
cd ~
wget https://www.python.org/ftp/python/3.10.0/Python-3.10.0.tgz
tar xzf Python-3.10.0.tgz
cd Python-3.10.0

# Configure and install to home directory
./configure --prefix=$HOME/python3.10
make
make install

# Add to PATH
echo 'export PATH=$HOME/python3.10/bin:$PATH' >> ~/.bashrc
source ~/.bashrc
