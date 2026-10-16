# Rockchip DKMS driver for IR remote control (rockchip-pwm-remotectrl) for the mainline kernel

original code from the armbian rk35xx linux-rockchip kernel  



## Install DKMS 


```bash
sudo git clone https://github.com/joilh/rk-remotectrl.git /usr/src/rk-remotectrl
sudo dkms build rk-remotectrl/7.3
sudo dkms autoinstall
```
