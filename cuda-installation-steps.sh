# 1. Download the CUDA toolkit (adjust version as needed)
wget https://developer.download.nvidia.com/compute/cuda/12.2.0/local_installers/cuda_12.2.0_535.54.03_linux.run

# 2. Make the installer executable
chmod +x cuda_12.2.0_535.54.03_linux.run

# 3. Extract the CUDA toolkit (this step may take some time)
./cuda_12.2.0_535.54.03_linux.run --toolkit --toolkitpath=$HOME/cuda_12.2 --defaultroot=$HOME/cuda_12.2 --silent

# 4. Set up environment variables
echo 'export PATH=$HOME/cuda_12.2/bin:$PATH' >> ~/.bashrc
echo 'export LD_LIBRARY_PATH=$HOME/cuda_12.2/lib64:$LD_LIBRARY_PATH' >> ~/.bashrc

# 5. Reload the ~/.bashrc file
source ~/.bashrc

# 6. Verify the installation
$HOME/cuda_12.2/bin/nvcc --version

# 7. Create an alias for nvcc
echo 'alias nvcc=$HOME/cuda_12.2/bin/nvcc' >> ~/.bashrc
source ~/.bashrc

# 8. Download CUDA samples from GitHub
git clone https://github.com/NVIDIA/cuda-samples.git $HOME/cuda-samples
cd $HOME/cuda-samples
git checkout v12.2  # Replace with your CUDA version if different

# 9. Compile and run a sample (deviceQuery)
cd $HOME/cuda-samples/Samples/1_Utilities/deviceQuery
make CUDA_PATH=$HOME/cuda_12.2
./deviceQuery

# 10. If you want to compile other samples, you may need to modify their Makefiles:
# Open the Makefile in a text editor (replace 'nano' with your preferred editor)
# nano Makefile
# Look for a line that sets CUDA_PATH, and change it to:
# CUDA_PATH ?= $(HOME)/cuda_12.2
# Save and exit the editor
