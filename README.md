### Share your internet connection with other devices, using an Ethernet cable

```
INTERNET
    |
    |
    V
WiFi Router
    |
    |
    V
Main device (can use the Internet normally)
    |
    |
    V
This script
    |
    |
    V                        .----> Downstream device 1 (can use the Internet normally)
Main device's Ethernet port(s) ---> Downstream device 2 (can use the Internet normally)
                             `----> Downstream device 3 (can use the Internet normally)
```

This is useful for when you only have one WiFi adapter, but you want multiple devices to use that one internet connection, without buying any additional hardware.  
With this script, I'm using a Raspberry Pi's built-in ethernet port to share its internet connection to other downstream devices.

### Preparation
Install dependencies, clone the repository
```
sudo apt install yad dnsmasq tcpdump
git clone https://github.com/Botspot/ethernet-hotspot
```
Please note that this script assumes your distro uses NetworkManager (most common ones do)

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
