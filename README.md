### Share your internet connection with other devices, using an Ethernet cable
<img width="2543" height="1083" alt="eth-hotspot-diagram" src="https://github.com/user-attachments/assets/5cfd1836-6cd1-4d85-8f89-b5c4e092dfde" />

This is useful for when you only have one WiFi adapter, but you want multiple devices to use that one internet connection, without buying any additional hardware.  
With this script, I'm using a Raspberry Pi's built-in ethernet port to share its internet connection to other downstream devices.

To connect multiple devices downstream, use an ethernet switch.

### Preparation
Install dependencies, clone the repository
```
sudo apt install yad dnsmasq tcpdump iptables
git clone https://github.com/Botspot/ethernet-hotspot
```
Please note that this script assumes your distro uses NetworkManager. (most common ones do)

### Usage
1. Run the script.
    ```
    sudo ./ethernet-hotspot/run.sh
    ```
2. Choose a network adapter (ethernet or wifi) whose internet connection you'd like to share:  
    <img width="293" height="103" alt="image" src="https://github.com/user-attachments/assets/5a916566-6293-4b21-a22f-a0bf1ada23e2" />
3. Next, choose another network adapter (ethernet only) to share to other devices that have an ethernet port:  
    <img width="490" height="103" alt="image" src="https://github.com/user-attachments/assets/395ee046-958d-4d3b-805b-597c913800b8" />
4. Done!
    - Watch the terminal output for errors.
    - Press Ctrl+C in the terminal to stop the script.

This script accepts arguments, for those who want to pre-select the appropriate network adapters every time, are on a headless OS, etc.  
Simply run `ifconfig` to get an idea of what your network adapters are called, then run the script like this: (change wlan1 and eth0 to suit your setup)
```
sudo ./ethernet-hotspot/run.sh wlan1 eth0
```
