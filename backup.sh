#!/usr/bin/env bash

SUFFIX_LEN=3
EXCLUDE_FILE=exclude.txt
MASTER_INDEX=backups.idx
RULES_CONF=rules.conf
SNAPSHOT_DIR=snap/
BACKUP_DIR=arch/
STANDARD_ARCH_OPTS=( --xattrs --numeric-owner --atime-preserve=system --preserve-permissions --bzip2 )

debug() {
    echo "$@" 1>&2
}

warn() {
    echo "$@" 1>&2
}

error() {
    warn "Error: " "$@"
    [[ -z "$2" ]] && exit '255' || exit "$2"
}

sanitize_sed() {
    sed 's/[\/&]/\\&/g' <<< "$1"
}

set_IFS() {
    local old_IFS="$IFS"
    IFS="$1"
    echo "$old_IFS"
}

reset_IFS() {
    IFS="$1"
}

sanitize_paths() {
    tr -s '/' <<< "$1"
}

archive() {
    local src dst idx split IFS
    local tar_opts split_opts cmd_tar cmd_split
    local idx_sed dst_sed
    src="$(sanitize_paths "$1")"
    dst="$(sanitize_paths "$2")"
    idx="$(sanitize_paths "$3")"
    split="$4"

    if [[ -z "$src" ]]; then
        error "No source specified, aborting"
    elif [[ -z "$dst" ]]; then
        error "No destination specified, aborting"
    fi

    if [[ "$DEBUG" -ge 1 ]]; then
        debug "src directory is: $src"
        debug "dst file is: $dst"
        debug "index file is: $idx"
        debug "split is: $split"
    fi

    # prepare command
    IFS=' '
    tar_opts=( --exclude-from="$EXCLUDE_FILE" )
    if [[ -n "$idx" ]]; then
        tar_opts+=( --listed-incremental="$idx" )
    fi
    tar_opts+=( "${STANDARD_ARCH_OPTS[@]}" --create )
    if [[ -z "$split" ]]; then
        tar_opts+=( --verbose --verbose --file="$dst" )
    fi
    tar_opts+=( -C "$src" . )

    split_opts=(  )
    if [[ -n "$split" ]]; then
        split_opts+=( --bytes="$split" --suffix-length="$SUFFIX_LEN")
    fi

    cmd_tar=( tar "${tar_opts[@]}" )
    cmd_split=( split "${split_opts[@]}" - "$dst." )

    if [[ "$DEBUG" -ge 1 ]]; then
        debug "tar cmd: " "${cmd_tar[@]}"
        debug "split cmd: " "${cmd_split[@]}"
    fi

    # archive
    if [[ -z "$split" ]]; then
        "${cmd_tar[@]}"
    else
        "${cmd_tar[@]}" | "${cmd_split[@]}"
    fi

    # update index database
    # we do this only after the actual archiving is done to prevent another process starting later
    # on basing using this archive as a level n-1 dump.
    # format: every line is one entry, beginning with the index filename followed by a colon (':')
    # after this there is a ordered, space seperated list of files which need to be restored.
    if [[ -n "$idx" ]]; then
        if [[ -n "$(grep "^$idx:.*$" "$MASTER_INDEX")" ]]; then
            idx_sed="$(sanitize_sed "$idx")"
            dst_sed="$(sanitize_sed "$dst")"
            if [[ "$DEBUG" -ge 1 ]]; then
                debug "sed regex: /^$idx_sed:/ s/$/ $dst_sed/"
            fi
            sed -i "/^$idx_sed:/ s/$/ $dst_sed/" "$MASTER_INDEX"
        else
            echo "$idx: $dst" >> "$MASTER_INDEX"
        fi
    fi
}

restore_ign_idx() {
    local src dst idx split IFS
    local cat_opts tar_opts cmd_cat cmd_tar
    src="$(sanitize_paths "$1")"
    dst="$(sanitize_paths "$2")"
    idx="$(sanitize_paths "$3")"
    split=

    if [[ -z "$src" ]]; then
        error "No source specified, aborting"
    elif [[ -z "$dst" ]]; then
        error "No destination specified, aborting"
    fi

    if [[ -f "$src" ]]; then
        split=
    else
        if ls "$src."* 1> /dev/null 2>&1; then
            split=true
        else
            error "Archive does not exist!"
        fi
    fi

    IFS=' '
    cat_opts=( "$src."* )
    tar_opts=(  )
    if [[ -n "$idx" ]]; then
        tar_opts+=( --listed-incremental=/dev/null )
    fi
    tar_opts+=( "${STANDARD_ARCH_OPTS[@]}" --extract )
    if [[ -z "$split" ]]; then
        tar_opts+=( --verbose --verbose --file="$src" )
    fi
    tar_opts+=( --directory="$dst" )

    cmd_cat=( cat "${cat_opts[@]}" )
    cmd_tar=( tar "${tar_opts[@]}" )

    if [[ -z "$split" ]]; then
        "${cmd_tar[@]}"
    else
        "${cmd_cat[@]}" | "${cmd_tar[@]}"
    fi
}

restore() {
    local src dst restore_order
    local idx idx_sed arch
    src="$(sanitize_paths "$1")"
    dst="$(sanitize_paths "$2")"

    if [[ -z "$src" ]]; then
        error "No source specified, aborting"
    elif [[ -z "$dst" ]]; then
        error "No destination specified, aborting"
    fi

    restore_order="$(grep "\( \|:\)$src\( \|\$\)" "$MASTER_INDEX")"
    # idx="$(grep -o '^[^:]*' <<< "$restore_order")"
    idx="$(sed -n 's/\(^.*\): .*$/\1/p' <<< "$restore_order")"
    idx_sed="$(sanitize_sed "$idx")"
    restore_order="$(sed "s/$idx_sed://" <<< "$restore_order")"

    echo "restore_order: $restore_order"
    echo "index: $idx"

    if [[ -z "$idx" ]]; then
        restore_ign_idx "$src" "$dst"
    else
        read -ra restore_order <<< "$restore_order"
        for arch in "${restore_order[@]}"; do
            restore_ign_idx "$arch" "$dst"
        done

    fi

}

branch() {
    local idx idx_new entry new_entry
    local idx_sed idx_new_sed
    idx="$(sanitize_paths "$1")"
    idx_new="$(sanitize_paths "$2")"

    entry="$(grep "^$idx:" "$MASTER_INDEX")"
    new_entry="$(grep "^$idx_new:" "$MASTER_INDEX")"

    if [[ -z "$entry" ]]; then
        error "Index does not exist, can't branch, aborting"
    elif [[ -n "$new_entry" ]]; then
        error "New index does already exist, would generate duplicate entry, aborting"
    fi

    idx_sed="$(sanitize_sed "$idx")"
    idx_new_sed="$(sanitize_sed "$idx_new")"
    entry="$(sed "s/$idx_sed/$idx_new_sed/" <<< "$entry")"
    echo "$entry" >> "$MASTER_INDEX"
    cp "$idx" "$idx_new"
}

generate_filename() {
    local type_name="$1"
    printf 'b%s_%s,%s' "$type_name" $(date -Iseconds) $(date +%V.%u)
}

match_existing_files() {
    local match_string type_name IFS
    local arr_names arr_subs
    match_string="$1"
    type_name="$2"

    IFS=' '
    arr_names=( TN % YYYY MM DD hh mm ss TZ CW WD self)
    arr_subs=( "$type_name" % $(date '+%Y %m %d %H %M %S %:z %V %u') "$(generate_filename "$type_name")" )

    IFS=$'\n'
    for ((i=0; i<${#arr_names[@]}; i++)); do
        match_string="$(sed "s/%${arr_names[$i]}/${arr_subs[$i]}/" <<< "$match_string")"
    done

    if [[ "$DEBUG" -ge 1 ]]; then
        debug "Match string for files: $match_string"
    fi

    find "$BACKUP_DIR" -type f -regextype sed -regex "\(.*/\|^\)$match_string.*" -exec basename {} \;
}

match_name() {
    local match_string type_name IFS
    local arr_names arr_subs name
    match_string="$1"
    type_name="$2"

    IFS=' '
    arr_names=( TN % YYYY MM DD hh mm ss TZ CW WD self )
    arr_subs=( "$type_name" % $(date '+%Y %m %d %H %M %S %:z %V %u') "$(generate_filename "$type_name")" )

    IFS=$'\n'
    for ((i=0; i<${#arr_names[@]}; i++)); do
        match_string="$(sed "s/%${arr_names[$i]}/${arr_subs[$i]}/" <<< "$match_string")"
    done

    name="$(generate_filename "$type_name")"

    match_string="^$match_string\$"
    if [[ "$name" =~ $match_string ]]; then
        echo "$name"
    fi
}

create_backup() {
    local filename l0backup directory idx
    filename="$1"
    l0backup="$2"
    directory="$3"

    echo "Backing up $directory to $filename"
    if [[ -n "$l0backup" ]]; then
        echo "Backup l0 dump is: $l0backup"
    fi

    idx=
    if [[ -n "$l0backup" ]]; then
        idx="$l0backup.svnr"
    fi

    if [[ -n "$idx" ]]; then
        echo "Branching from $idx to $filename.svnr"
        branch "$SNAPSHOT_DIR/$idx" "$SNAPSHOT_DIR/$filename.svnr"
    fi

    echo "archive: $BACKUP_DIR/$filename.tar.bz2"
    echo "index:   $SNAPSHOT_DIR/$filename.svnr"
    archive "$directory" "$BACKUP_DIR/$filename.tar.bz2" "$SNAPSHOT_DIR/$filename.svnr"
}

managed_cycle() {
    local line IFS var_val old_IFS
    local match_exist_name_ss match_exist_name_s
    local match_name_ss match_name_s
    local l0back
    local entry_name=
    local type=
    local incremental_match_base=
    local incremental_match_base_alt=
    local match_exist_name=
    local match_name=
    local directory=


    IFS=$'\n'
    while read -r line; do

        # comments are '#' trim them and if the line is empty skip it (this also gets rid of trailing newlines).
        line="$(sed 's/#.*//' <<< "$line")"
        if [[ -z "$line" ]]; then
            continue
        fi
        var_val=
        old_IFS="$IFS"
        IFS=$'\t''= ' # we don't want trailing or leading spaces/tabs
        read -ra var_val <<< "$line"
        IFS="$old_IFS"

        if [[ "$DEBUG" -ge 2 ]]; then
            echo "[${var_val[0]}] [${var_val[1]}]"
        fi

        # is the current line a tag? [XXXX]
        # if so the previous tag has been filled with all needed variables.
        if [[ ${#var_val[@]} = 1 ]] && [[ "${var_val[0]}" =~ \[..*\] ]]; then
            # handle the entry, it has already been read in
            if [[ "$entry_name" =~ ..* ]]; then
                echo "Checking target: $entry_name"

                match_exist_name_ss="$(match_existing_files "$match_exist_name" "$entry_name")"
                match_name_ss="$(match_name "$match_name" "$entry_name")"
                match_exist_name_s=( $match_exist_name_ss )
                match_name_s="$match_name_ss"

                if [[ "$DEBUG" -ge 1 ]]; then
                    echo "match_exist_name_ss"
                    printf '%s\n' "$match_exists_name_ss"
                    echo "match_exist_name_s"
                    printf '[%s]\n' "${match_exist_name_s[@]}"
                    echo "match_name_s"
                    printf '%s\n' "$match_name_s"
                fi

                # check backup conditions and perform backup
                if [[ ${#match_exist_name_s[@]} = 0 ]] && [[ -n "$match_name_s" ]]; then
                    echo "No prohibiting files found (checked against $match_exist_name)"
                    echo "Backup file will be: $match_name_s"

                    # if the type is incremental, determine the correct l0 dump
                    l0back=
                    if [[ "$type" = incremental ]]; then
                        l0back="$(match_existing_files "$incremental_match_base" "$entry_name")"
                        if [[ "$DEBUG" -ge 1 ]]; then
                            echo "found possible l0 backups:"
                            echo "$l0back"
                        fi
                        l0back=( $(sort -t'_' -k2 <<< "${l0back[*]}" | tac) )
                        # shellcheck disable=SC2178
                        l0back="$(sed 's/\.tar\..*$//' <<< "${l0back[0]}")"
                    fi

                    if [[ -z "$DRYRUN" ]]; then
                        create_backup "$match_name_s" "$l0back" "$directory"
                    else
                        echo create_backup "$match_name_s" "$l0back" "$directory"
                    fi
                else
                    echo "Backup requirements already satisfied, nothing to do"
                fi
            fi

            # start reading of new entry
            entry_name="$(tr -d '\]\[' <<< "${var_val[0]}")"
            type=
            incremental_match_base=
            incremental_match_base_alt=
            match_exist_name=
            match_name=
            directory=
            continue
        fi
        if [[ -n "${var_val[0]}" ]]; then
            local "${var_val[0]}"="${var_val[1]}"
        fi
    done < "$RULES_CONF"
}

sat_structure() {
    mkdir -p "$(dirname "$EXCLUDE_FILE")"
    mkdir -p "$(dirname "$MASTER_INDEX")"
    mkdir -p "$(dirname "$RULES_CONF")"
    mkdir -p "$SNAPSHOT_DIR"
    mkdir -p "$BACKUP_DIR"

    touch "$EXCLUDE_FILE"
    touch "$MASTER_INDEX"
    touch "$RULES_CONF"
    touch "$SNAPSHOT_DIR"
    touch "$BACKUP_DIR"
}

unset IFS
sat_structure
"$@"
