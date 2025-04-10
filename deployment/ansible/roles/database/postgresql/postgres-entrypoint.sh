#!/bin/bash
set -e

# Replace env vars in config files at runtime if templates exist
if [[ -f /etc/postgresql/postgresql.conf.template ]]; then
  envsubst < /etc/postgresql/postgresql.conf.template > "$PGDATA/postgresql.conf"
fi

if [[ -f /etc/postgresql/pg_hba.conf.template ]]; then
  envsubst < /etc/postgresql/pg_hba.conf.template > "$PGDATA/pg_hba.conf"
fi

# Add health check logic
wait_for_postgres() {
  local retries=30
  while ! pg_isready -h "$1" -U "$POSTGRES_USER"; do
    ((retries--))
    if [ $retries -eq 0 ]; then
      echo "Timeout waiting for PostgreSQL"
      exit 1
    fi
    echo "Waiting for PostgreSQL..."
    sleep 2
  done
}

# Function to replace environment variables in configuration files
replace_env_vars() {
    local file=$1
    
    # Substituting environment variables in repmgr.conf
    if [[ -n "$NODE_ID" ]]; then
        sed -i "s/NODE_ID/$NODE_ID/" $file
    fi
    
    if [[ -n "$NODE_NAME" ]]; then
        sed -i "s/NODE_NAME/$NODE_NAME/" $file
    fi
    
    if [[ -n "$NODE_HOST" ]]; then
        sed -i "s/NODE_HOST/$NODE_HOST/" $file
    fi
}

# Configure PostgreSQL for primary or replica mode
setup_postgresql() {
    # Copy pre-configured postgresql.conf and pg_hba.conf if they don't exist
    if [[ ! -s "$PGDATA/postgresql.conf" && -f /etc/postgresql/postgresql.conf ]]; then
        cp /etc/postgresql/postgresql.conf "$PGDATA/"
    fi
    
    if [[ ! -s "$PGDATA/pg_hba.conf" && -f /etc/postgresql/pg_hba.conf ]]; then
        cp /etc/postgresql/pg_hba.conf "$PGDATA/"
    fi
    
    # Configure pg_hba.conf to allow replication connections if not already present
    if [[ -f "$PGDATA/pg_hba.conf" ]] && ! grep -q "host replication postgres 0.0.0.0/0 md5" "$PGDATA/pg_hba.conf"; then
        cat >> "$PGDATA/pg_hba.conf" <<EOF
# Allow replication connections
host replication postgres 0.0.0.0/0 md5
host replication postgres ::/0 md5
EOF
    fi
}

# Check if database is already initialized
db_is_initialized() {
    # Check for PG_VERSION file which indicates an initialized database
    [[ -s "$PGDATA/PG_VERSION" ]]
}

# Initialize primary server
init_primary() {
    echo "Initializing primary PostgreSQL server..."
    
    # Create data directory if it doesn't exist or isn't initialized
    if ! db_is_initialized; then
        echo "Database not initialized. Running initdb..."
        # Run initdb as postgres user
        su postgres -c "initdb -D $PGDATA -U postgres"
        setup_postgresql
        
        # Start PostgreSQL temporarily to create replication slot
        echo "Starting PostgreSQL temporarily to create replication slot..."
        
        # Start PostgreSQL as postgres user
        su postgres -c "pg_ctl -D $PGDATA -w start"
        
        # Create replication slot as postgres user - simplified approach
        su postgres -c "psql -U postgres -c \"SELECT pg_create_physical_replication_slot('replication_slot', true, false);\" 2>/dev/null || true"
        
        # Stop PostgreSQL as postgres user
        su postgres -c "pg_ctl -D $PGDATA -w stop"
    else
        echo "Database already initialized. Skipping initdb."
        setup_postgresql
    fi
}

# Initialize replica server
init_replica() {
    echo "Initializing replica PostgreSQL server..."
    
    # Only proceed with replication setup if database isn't already initialized
    if ! db_is_initialized; then
        # Remove data directory contents if any exist
        rm -rf "$PGDATA"/*

        # Wait for primary to be ready for replication
        echo "Waiting for primary to be fully initialized..."
        sleep 30  

        # Then verify primary is ready for replication connections
        until su postgres -c "psql -h $REPLICATE_FROM -U postgres -c 'SELECT pg_is_in_recovery();'"; do
            echo "Waiting for primary to accept connections..."
            sleep 5
        done
        
        # Try to connect to primary and perform base backup
        # Run pg_basebackup as postgres user
        until su postgres -c "pg_basebackup -h $REPLICATE_FROM -D $PGDATA -U postgres -X stream -P"; do
            echo "Waiting for primary to be ready..."
            sleep 5
        done
        
        # Create recovery configuration
        cat > "$PGDATA/postgresql.auto.conf" <<EOF
primary_conninfo = 'host=$REPLICATE_FROM port=5432 user=postgres password=''$POSTGRES_PASSWORD'' application_name=$NODE_NAME'
primary_slot_name = 'replication_slot'
hot_standby = on
EOF

        # Create standby signal file
        touch "$PGDATA/standby.signal"
    else
        echo "Database already initialized. Checking if it's configured as replica..."
        if [[ -f "$PGDATA/standby.signal" ]]; then
            echo "Already configured as replica. Updating configuration..."
            # Update recovery configuration with current settings
            cat > "$PGDATA/postgresql.auto.conf" <<EOF
primary_conninfo = 'host=$REPLICATE_FROM port=5432 user=postgres password=''$POSTGRES_PASSWORD'' application_name=$NODE_NAME'
primary_slot_name = 'replication_slot'
hot_standby = on
EOF
        else
            echo "WARNING: Existing database is not configured as replica but ROLE=replica was specified."
            echo "Manual intervention may be required."
        fi
    fi
}

# Main entrypoint logic
if [[ "$ROLE" == "primary" ]]; then
    echo "Configuring node as PRIMARY"
    init_primary
elif [[ "$ROLE" == "replica" ]]; then
    echo "Configuring node as REPLICA"
    if [[ -z "$REPLICATE_FROM" ]]; then
        echo "Error: REPLICATE_FROM environment variable not set. Cannot configure replica."
        exit 1
    fi
    
    if ! db_is_initialized; then
        # Wait for the primary to be available
        until pg_isready -h $REPLICATE_FROM -U postgres; do
            echo "Waiting for primary node to be available..."
            sleep 5
        done
    fi
    
    init_replica
else
    echo "ROLE not specified (primary or replica). Running as standalone instance."
    # Default initialization
    if ! db_is_initialized; then
        echo "Initializing database..."
        su postgres -c "initdb -D $PGDATA -U postgres"
        setup_postgresql
    else
        echo "Database already initialized. Skipping initdb."
        setup_postgresql
    fi
fi

# Ensure proper ownership of the data directory
chown -R postgres:postgres "$PGDATA"

# Copy repmgr.conf if it exists
if [[ -f /etc/repmgr.conf ]]; then
    cp /etc/repmgr.conf /var/lib/postgresql/repmgr.conf
    replace_env_vars /var/lib/postgresql/repmgr.conf
    chown postgres:postgres /var/lib/postgresql/repmgr.conf
fi

# Start PostgreSQL as postgres user
echo "Starting PostgreSQL server..."
exec su postgres -c "postgres -D $PGDATA"