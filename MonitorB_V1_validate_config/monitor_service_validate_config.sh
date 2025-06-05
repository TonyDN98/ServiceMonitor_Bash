#!/bin/bash

# Process Monitor Service
#
# This script monitors processes by checking their status in a MySQL database
# and restarts them when they are in alarm state.
# Designed for RedHat Linux environments.

# Set up logging
LOG_FILE="/var/log/monitor_service.log"

# Load configuration
CONFIG_FILE="config.ini"

# Configuration validation constants
REQUIRED_CONFIG_SECTIONS=("database" "monitor")
REQUIRED_DB_PARAMS=("host" "user" "password" "database")
REQUIRED_MONITOR_PARAMS=("check_interval" "max_restart_failures" "circuit_reset_time")
MIN_CHECK_INTERVAL=5
MAX_CHECK_INTERVAL=3600
MIN_RESTART_FAILURES=1
MAX_RESTART_FAILURES=10
MIN_CIRCUIT_RESET_TIME=30
MAX_CIRCUIT_RESET_TIME=86400

log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "$timestamp - $level - $message" | tee -a "$LOG_FILE"
}

# Read configuration from config.ini
read_config() {
    # Validate config file exists and has correct permissions
    if ! validate_config_file; then
        return 1
    fi

    # Parse database section
    DB_HOST=$(sed -n '/^\[database\]/,/^\[/p' "$CONFIG_FILE" | grep "^host[[:space:]]*=" | cut -d'=' -f2 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    DB_USER=$(sed -n '/^\[database\]/,/^\[/p' "$CONFIG_FILE" | grep "^user[[:space:]]*=" | cut -d'=' -f2 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    DB_PASS=$(sed -n '/^\[database\]/,/^\[/p' "$CONFIG_FILE" | grep "^password[[:space:]]*=" | cut -d'=' -f2 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    DB_NAME=$(sed -n '/^\[database\]/,/^\[/p' "$CONFIG_FILE" | grep "^database[[:space:]]*=" | cut -d'=' -f2 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    # Parse monitor section
    CHECK_INTERVAL=$(sed -n '/^\[monitor\]/,/^\[/p' "$CONFIG_FILE" | grep "^check_interval[[:space:]]*=" | cut -d'=' -f2 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    MAX_RESTART_FAILURES=$(sed -n '/^\[monitor\]/,/^\[/p' "$CONFIG_FILE" | grep "^max_restart_failures[[:space:]]*=" | cut -d'=' -f2 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    CIRCUIT_RESET_TIME=$(sed -n '/^\[monitor\]/,/^\[/p' "$CONFIG_FILE" | grep "^circuit_reset_time[[:space:]]*=" | cut -d'=' -f2 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    # Debug output for validation
    log "DEBUG" "Parsed configuration values:"
    log "DEBUG" "DB_HOST='$DB_HOST'"
    log "DEBUG" "DB_USER='$DB_USER'"
    log "DEBUG" "DB_NAME='$DB_NAME'"
    log "DEBUG" "CHECK_INTERVAL='$CHECK_INTERVAL'"

    # Validate that we got all required values
    if [ -z "$DB_HOST" ] || [ -z "$DB_USER" ] || [ -z "$DB_PASS" ] || [ -z "$DB_NAME" ] || \
       [ -z "$CHECK_INTERVAL" ] || [ -z "$MAX_RESTART_FAILURES" ] || [ -z "$CIRCUIT_RESET_TIME" ]; then
        log "ERROR" "Failed to parse one or more configuration values from $CONFIG_FILE"
        exit 1
    fi

    # Export variables for use in script
    export DB_HOST DB_USER DB_PASS DB_NAME
    export CHECK_INTERVAL MAX_RESTART_FAILURES CIRCUIT_RESET_TIME

    # Verify values are numeric where required
    if ! [[ "$CHECK_INTERVAL" =~ ^[0-9]+$ ]] || \
       ! [[ "$MAX_RESTART_FAILURES" =~ ^[0-9]+$ ]] || \
       ! [[ "$CIRCUIT_RESET_TIME" =~ ^[0-9]+$ ]]; then
        log "ERROR" "Invalid numeric values in configuration"
        exit 1
    fi
}

# Validate configuration file permissions and existence
validate_config_file() {
    if [ ! -f "$CONFIG_FILE" ]; then
        log "ERROR" "Configuration file $CONFIG_FILE not found"
        return 1
    fi

    # Check if file is readable
    if [ ! -r "$CONFIG_FILE" ]; then
        log "ERROR" "Configuration file $CONFIG_FILE is not readable"
        return 1
    fi

    # Check if file permissions are secure (only owner can read/write)
    local perms=$(stat -c %a "$CONFIG_FILE" 2>/dev/null || echo "600")
    if [ "$perms" != "600" ]; then
        log "WARNING" "Configuration file $CONFIG_FILE has insecure permissions: $perms. Recommended: 600"
    fi

    return 0
}

# Validate numeric value within range
validate_numeric_range() {
    local param_name="$1"
    local value="$2"
    local min="$3"
    local max="$4"

    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
        log "ERROR" "Parameter $param_name must be a positive integer"
        return 1
    fi

    if [ "$value" -lt "$min" ] || [ "$value" -gt "$max" ]; then
        log "ERROR" "Parameter $param_name must be between $min and $max"
        return 1
    fi

    return 0
}

# Validate database parameters
validate_db_params() {
    local host="$1"
    local user="$2"
    local pass="$3"
    local db="$4"

    # Check for empty values
    if [ -z "$host" ] || [ -z "$user" ] || [ -z "$pass" ] || [ -z "$db" ]; then
        log "ERROR" "All database parameters must be non-empty"
        return 1
    fi

    # Validate hostname format
    if ! [[ "$host" =~ ^[a-zA-Z0-9.-]+$ ]]; then
        log "ERROR" "Invalid database host format: $host"
        return 1
    fi

    # Validate database name format
    if ! [[ "$db" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log "ERROR" "Invalid database name format: $db"
        return 1
    fi

    return 0
}

# Main configuration validation
validate_config() {
    local config_valid=true

    # Validate database section
    if ! validate_db_params "$DB_HOST" "$DB_USER" "$DB_PASS" "$DB_NAME"; then
        config_valid=false
    fi

    # Validate monitor section parameters
    if ! validate_numeric_range "check_interval" "$CHECK_INTERVAL" "$MIN_CHECK_INTERVAL" "$MAX_CHECK_INTERVAL"; then
        config_valid=false
    fi

    if ! validate_numeric_range "max_restart_failures" "$MAX_RESTART_FAILURES" "$MIN_RESTART_FAILURES" "$MAX_RESTART_FAILURES"; then
        config_valid=false
    fi

    if ! validate_numeric_range "circuit_reset_time" "$CIRCUIT_RESET_TIME" "$MIN_CIRCUIT_RESET_TIME" "$MAX_CIRCUIT_RESET_TIME"; then
        config_valid=false
    fi

    if [ "$config_valid" = false ]; then
        log "ERROR" "Configuration validation failed. Please check the configuration file."
        return 1
    fi

    log "INFO" "Configuration validation successful"
    return 0
}

# Get processes in alarm state
get_alarm_processes() {
    mysql -N -u"$DB_USER" -p"$DB_PASS" -h"$DB_HOST" "$DB_NAME" <<EOF
    SELECT CONCAT(p.process_id, '|', p.process_name, '|', s.alarma, '|', s.sound, '|', s.notes)
    FROM STATUS_PROCESS s
    JOIN PROCESE p ON s.process_id = p.process_id
    WHERE s.alarma = 1 AND s.sound = 0;
EOF
}

# Restart a process or service
restart_process() {
    local process_name="$1"
    log "INFO" "RESTART LOG: Beginning restart procedure for $process_name"
    
    # Try to restart as a systemd service first
    if systemctl restart "$process_name" 2>/dev/null; then
        log "INFO" "RESTART LOG: Successfully restarted service: $process_name"
        return 0
    else
        log "WARNING" "RESTART LOG: Failed to restart as service: $process_name"
        log "WARNING" "RESTART LOG: Trying as process instead"
        
        # Try to kill the process
        if pkill "$process_name"; then
            log "INFO" "RESTART LOG: Successfully killed process: $process_name"
            
            # Wait a moment before starting
            sleep 2
            
            # Try to start the process
            if "$process_name" >/dev/null 2>&1 & then
                log "INFO" "RESTART LOG: Successfully started process: $process_name"
                return 0
            else
                log "ERROR" "RESTART LOG: Failed to start process: $process_name"
                return 1
            fi
        else
            log "ERROR" "RESTART LOG: Failed to kill process: $process_name"
            return 1
        fi
    fi
}

# Update alarm status in database
update_alarm_status() {
    local process_id="$1"
    local current_time=$(date '+%Y-%m-%d %H:%M:%S')
    
    mysql -u"$DB_USER" -p"$DB_PASS" -h"$DB_HOST" "$DB_NAME" <<EOF
    UPDATE STATUS_PROCESS 
    SET alarma = 0, notes = CONCAT(notes, ' - Restarted at $current_time')
    WHERE process_id = $process_id;
EOF
    
    if [ $? -eq 0 ]; then
        log "INFO" "DB UPDATE LOG: Successfully updated alarm status for process_id: $process_id"
        return 0
    else
        log "ERROR" "DB UPDATE LOG: Failed to update alarm status for process_id: $process_id"
        return 1
    fi
}

# Circuit breaker implementation
declare -A circuit_breaker
declare -A failure_counts
declare -A last_failure_times

check_circuit_breaker() {
    local process_name="$1"
    local current_time=$(date +%s)
    
    # Initialize if not exists
    if [ -z "${circuit_breaker[$process_name]}" ]; then
        circuit_breaker[$process_name]="closed"
        failure_counts[$process_name]=0
        last_failure_times[$process_name]=$current_time
    fi
    
    # Check if circuit breaker is open
    if [ "${circuit_breaker[$process_name]}" = "open" ]; then
        local time_diff=$((current_time - ${last_failure_times[$process_name]}))
        if [ $time_diff -ge "$CIRCUIT_RESET_TIME" ]; then
            circuit_breaker[$process_name]="closed"
            failure_counts[$process_name]=0
            log "INFO" "Circuit breaker reset for $process_name"
            return 0
        else
            log "WARNING" "Circuit breaker open for $process_name. Skipping restart."
            return 1
        fi
    fi
    
    return 0
}

update_circuit_breaker() {
    local process_name="$1"
    local success="$2"
    local current_time=$(date +%s)
    
    if [ "$success" = "false" ]; then
        failure_counts[$process_name]=$((failure_counts[$process_name] + 1))
        last_failure_times[$process_name]=$current_time
        
        if [ ${failure_counts[$process_name]} -ge "$MAX_RESTART_FAILURES" ]; then
            circuit_breaker[$process_name]="open"
            log "WARNING" "Circuit breaker opened for $process_name after ${failure_counts[$process_name]} failures"
        fi
    else
        failure_counts[$process_name]=0
    fi
}

# Main monitoring loop
main() {
    log "INFO" "Starting Process Monitor Service"
    
    # Read configuration
    if ! read_config; then
        log "ERROR" "Failed to read configuration. Exiting."
        exit 1
    fi
    
    # Validate configuration
    if ! validate_config; then
        log "ERROR" "Configuration validation failed. Exiting."
        exit 1
    fi
    
    # Validate configuration
    if ! validate_config; then
        log "ERROR" "Configuration validation failed. Exiting."
        exit 1
    fi
    
    while true; do
        # Get processes in alarm state
        while IFS='|' read -r process_id process_name alarma sound notes; do
            if [ -n "$process_id" ]; then
                log "INFO" "Found process in alarm: $process_name (ID: $process_id)"
                
                # Check circuit breaker
                if check_circuit_breaker "$process_name"; then
                    # Attempt restart
                    if restart_process "$process_name"; then
                        update_alarm_status "$process_id"
                        update_circuit_breaker "$process_name" "true"
                        log "INFO" "Successfully handled alarm for $process_name"
                    else
                        update_circuit_breaker "$process_name" "false"
                        log "ERROR" "Failed to handle alarm for $process_name"
                    fi
                fi
            fi
        done < <(get_alarm_processes)
        
        # Wait for next check interval
        sleep "$CHECK_INTERVAL"
    done
}

# Start the monitor
main
