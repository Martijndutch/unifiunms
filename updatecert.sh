#!/bin/bash

# Paths to the certificates and keys
CERT_DIR="/home/unms/data/cert"
CERT_FILE="$CERT_DIR/live.crt"
KEY_FILE="$CERT_DIR/live.key"

# UniFi controller directory (update this if UniFi is installed in a different location)
UNIFI_DIR="/usr/lib/unifi"
UNIFI_CERT_DIR="$UNIFI_DIR/data"
UNIFI_SERVICE="unifi"
LOG_FILE="/root/unifi_cert_update.log"

# Test mode flag (default to "no")
TEST_MODE="no"

# Full path to the script 
SCRIPT_PATH="$(realpath "$0")"

# Check for --test parameter
if [[ "$1" == "--test" && "$2" == "yes" ]]; then
    TEST_MODE="yes"
    echo "$(date): Test mode enabled. No changes will be made to the UniFi Controller." | tee -a "$LOG_FILE"
fi

# Ensure the script is run as root
if [ "$(id -u)" != "0" ]; then
    echo "$(date): This script must be run as root." | tee -a "$LOG_FILE"
    exit 1
fi

# Function to get the fingerprint of a certificate using OpenSSL
get_certificate_fingerprint() {
    local cert_path=$1
    openssl x509 -noout -fingerprint -sha256 -in "$cert_path" | sed 's/://g' | awk -F'=' '{print $2}' | tr -d '\n'
}

# Function to get the current UniFi certificate fingerprint from the keystore
get_unifi_keystore_fingerprint() {
    local keystore_path=$1
    keytool -list -keystore "$keystore_path" -storepass aircontrolenterprise -alias unifi 2>/dev/null \
    | grep "Certificate fingerprint (SHA-256)" | sed 's/://g' | awk '{print $4}' | tr -d '\n'
}

# Function to schedule the script in cron if not already scheduled
schedule_cron_job() {
    local cron_job="0 1 * * * /bin/bash $SCRIPT_PATH"
    if ! crontab -l | grep -q "$SCRIPT_PATH"; then
        echo "$(date): Scheduling the script to run daily at 1 AM as root." | tee -a "$LOG_FILE"
        (crontab -l 2>/dev/null; echo "$cron_job") | crontab -
    else
        echo "$(date): Script is already scheduled in cron." | tee -a "$LOG_FILE"
    fi
}

# Check if the script is already scheduled as a cron job, and schedule it if not
schedule_cron_job

# Check if the keystore exists
if [ ! -f "$UNIFI_CERT_DIR/keystore" ]; then
    echo "$(date): No existing keystore found. Proceeding with certificate installation." | tee -a "$LOG_FILE"
else
    # Get the fingerprints
    echo "$(date): Checking if the new certificate is already in use..." | tee -a "$LOG_FILE"
    current_fingerprint=$(get_unifi_keystore_fingerprint "$UNIFI_CERT_DIR/keystore")
    new_fingerprint=$(get_certificate_fingerprint "$CERT_FILE")

    # Debugging: Print fingerprints for comparison
    echo "$(date): Current Keystore Fingerprint: $current_fingerprint" | tee -a "$LOG_FILE"
    echo "$(date): New Certificate Fingerprint:  $new_fingerprint" | tee -a "$LOG_FILE"

    # Compare fingerprints
    if [ "$current_fingerprint" == "$new_fingerprint" ]; then
        echo "$(date): The certificate is already up to date. No changes necessary." | tee -a "$LOG_FILE"
        exit 0
    else
        echo "$(date): New certificate detected. Proceeding with the update." | tee -a "$LOG_FILE"
    fi
fi

# Perform actions if NOT in test mode
if [ "$TEST_MODE" == "no" ]; then
    # Stop UniFi Controller
    echo "$(date): Stopping UniFi Controller..." | tee -a "$LOG_FILE"
    systemctl stop $UNIFI_SERVICE
else
    echo "$(date): Test mode: Skipping UniFi Controller stop." | tee -a "$LOG_FILE"
fi

# Backup existing keystore (just in case)
echo "$(date): Backing up current keystore..." | tee -a "$LOG_FILE"
cp "$UNIFI_CERT_DIR/keystore" "$UNIFI_CERT_DIR/keystore.backup"

# Convert PEM to PKCS12 format (required by UniFi)
P12_FILE="$UNIFI_CERT_DIR/unifi.p12"
echo "$(date): Converting certificates to PKCS12 format..." | tee -a "$LOG_FILE"
openssl pkcs12 -export -inkey "$KEY_FILE" -in "$CERT_FILE" -out "$P12_FILE" -name unifi -password pass:aircontrolenterprise

# Import the new certificate into the UniFi keystore
if [ "$TEST_MODE" == "no" ]; then
    echo "$(date): Importing the new certificate into the UniFi keystore..." | tee -a "$LOG_FILE"
    keytool -importkeystore -deststorepass aircontrolenterprise -destkeypass aircontrolenterprise \
      -destkeystore "$UNIFI_CERT_DIR/keystore" -srckeystore "$P12_FILE" -srcstoretype PKCS12 \
      -srcstorepass aircontrolenterprise -alias unifi -noprompt
else
    echo "$(date): Test mode: Skipping certificate import." | tee -a "$LOG_FILE"
fi

# Set correct permissions for the keystore
echo "$(date): Setting permissions for the UniFi keystore..." | tee -a "$LOG_FILE"
chown unifi:unifi "$UNIFI_CERT_DIR/keystore"
chmod 600 "$UNIFI_CERT_DIR/keystore"

# Start UniFi Controller (only if NOT in test mode)
if [ "$TEST_MODE" == "no" ]; then
    echo "$(date): Starting UniFi Controller..." | tee -a "$LOG_FILE"
    systemctl start $UNIFI_SERVICE
else
    echo "$(date): Test mode: Skipping UniFi Controller start." | tee -a "$LOG_FILE"
fi

# Clean up PKCS12 file (optional, but recommended for security reasons)
rm -f "$P12_FILE"

# Log the completion of the script
if [ "$TEST_MODE" == "no" ]; then
    echo "$(date): SSL certificate installation for UniFi Controller is complete." | tee -a "$LOG_FILE"
else
    echo "$(date): Test mode: SSL certificate installation simulation complete." | tee -a "$LOG_FILE"
fi

