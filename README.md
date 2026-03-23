# 🖥️ Backup_pi 🚀

A professional, automated backup solution for Raspberry Pi. This script creates incremental, shrunk, and verified system images while keeping you updated via Telegram, Gotify or Ntfy.

## ✨ Key Features
- **Uses a .conf file for backup options**: Settings for type of backup, backup location, services and Docker containers, image-backup options, messaging and logging can be saved as the defaults for the backup. Backup file and log retention and post image creation options are also set in the .conf file.
- **Command Line Options to Override .conf Settings**: Command line options for starting a user backup or initial image-backup image so those can be run without changing the .conf settings file.
- **Automatic Folder Structure and File Naming**: Backup will be placed in the backup location specified in the .conf file under folders by hostname and OS Version with a filename created using that hostname, OS Version and date & time stamp.
- **Stopping and Re-starting of Services and Docker Containers**: If specified in the .conf file, prior to the backup, the specified Services and Docker containers will be stopped then re-started after the backup completes.
- **Smart Incremental Backups**: Uses image-backup and `rsync` to update the most recent existing image, saving time and SD card wear.
- **Auto-Shrink**: For backup images that will not be used for incremental backups, `pishrink.sh` can be used to keep image files as small as possible by further compressing them then using gzip on them.
- **Multi-Partition Trim**: If running from an SD card, dynamically finds and trims both `/boot` and `/` partitions.
- **Smart Notifications**: Sends success/alerts to **Telegram**, **Gotify** or **Ntfy** with a backup log if set to do so.
- **Environment Aware**: Automatically detects tool paths (`image-backup`, `rsync`, `fstrim`, etc.) and handles optional features gracefully.

## 🕹️ Usage ##

```text
Usage: Backup.sh [-u] or [-uc] or [-i]

  -u         Run a uncompressed user home folder backup.
  -uc        Run a compressed backup of the current user's home directory.
  -i         Run an initial image backup ready for incremental updating.
```
Using any options will overide the type of backup set in the `Backup.conf` file. If run with no additional options the settings in the `Backup.conf` file will be used when the backup is run.

* `-u`	Performs a uncompressed backup of the current user's home directory to a folder in the backup location
* `-uc`	Performs a tar and gzipped backup of the current users home directory to a file (.tar.gz) in the backup location
* `-i`	Overrides the .conf settings and performs an initial image backup (.img) ready for incremental updating


## 🛠️ Prerequisites
The script automatically checks for these. For full functionality, ensure you have:

- `rsync`, `fstrim`, `awk`

- image-utilities  from RonR in the RaspberryPi Forum - [https://forums.raspberrypi.com/viewtopic.php?t=332000#p1511694](https://forums.raspberrypi.com/viewtopic.php?t=332000#p1511694)

	- image-backup - Excellent utilitiy for making a backup image of a running Raspberry Pi.

	- image-check - Utility to check the status of an image file.

(optional)

- PiShrink and it's prerequisites [https://github.com/Drewsif/PiShrink](https://github.com/Drewsif/PiShrink)

- telegram-send - [Telegram-send](https://github.com/rahiel/telegram-send)
- telegram-send-group-topic - [https://github.com/tsqrdster/telegram-send-group-topic/raw/refs/heads/main/telegram-send-group-topic.sh](https://github.com/tsqrdster/telegram-send-group-topic/raw/refs/heads/main/telegram-send-group-topic.sh)
- telegram-send-group-topic-file - [https://github.com/tsqrdster/telegram-send-group-topic/raw/refs/heads/main/telegram-send-group-topic-file.sh](https://github.com/tsqrdster/telegram-send-group-topic/raw/refs/heads/main/telegram-send-group-topic-file.sh)
- gotify-send - [https://github.com/tsqrdster/gotify-send](https://github.com/tsqrdster/gotify-send)
- ntfy-send - [https://github.com/tsqrdster/ntfy-send](https://github.com/tsqrdster/ntfy-send)
- ntfy-send-file - [https://github.com/tsqrdster/ntfy-send](https://github.com/tsqrdster/ntfy-send)

## 🚀 Getting Started

1. **Clone the Repo:**

	```bash
	cd ~
	mkdir Installs
	cd Installs
	git clone https://github.com/tsqrdster/Backup_pi.git
	cd Backup_pi
	```
   
2. **Configure:**
Edit your .conf file (ensure it is in the same directory) to set your backup paths, options and messaging notifications. Make sure you have the backup location mounted (USB or network) and a `.USB_IS_HERE` file has been created in the folder you want to backup to.

	```bash
	cp Backup.conf.example Backup.conf
	nano Backup.conf
	# (make changes in regard to your backup location and options then save with  <ctrl>+o <enter> then exit  with  <ctrl>+x )
	
	# Make executable
	chmod +x Backup.sh
	# Create link to file in /usr/local/bin/
	# (replace "/home/pi/"  with correct user home location)
	sudo ln -s /home/pi/Installs/Backup_pi/Backup.sh /usr/local/bin/Backup.sh
		
	# Create a .USB_IS_HERE file in root of your configured backup directory
	# Replace "/mnt/backup" with your backup location
	touch /mnt/backup/.USB_IS_HERE	
	```

3. **Run a Manual Backup:**
Force an initial backup with space added to the .img file for incremental backups. When running manually it will re-start if not run with `sudo` privlidges and may ask for your `sudo` password.

    ```bash
    ./Backup.sh -i
    ```
    
4. **Automation:**
Add to your root crontab to run nightly:

	```bash
	sudo nano /etc/crontab
	```
	Add to bottom of file:
	```bash
	59 23   * * *   root    /bin/bash /usr/local/bin/Backup.sh > /dev/null 2>&1
	```

## 📜 License ##
This project is licensed under the MIT License - see the LICENSE file for details.
	
## 🤝 Contributing ##

If you find a bug please create an issue for it. Feel free to submit Pull Requests or open Issues if you find a bug or have ideas for new features or notification providers!
