#!/usr/bin/env bash

SUFFIX_LEN=3
EXCLUDE_FILE=back_exclude.txt
MASTER_INDEX=idx/backups.idx
RULES_CONF=creation.conf
SNAPSHOT_DIR=snap/
BACKUP_DIR=arch/

debug() {
    echo "$@" 1>&2
}

warn() {
    echo "$@" 1>&2
}

error() {
    warn "Error: $@"
    [[ -z "$2" ]] && exit '-1' || exit "$2"
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
    local src="$(sanitize_paths "$1")"
    local dst="$(sanitize_paths "$2")"
    local idx="$(sanitize_paths "$3")"
    local split="$4"

    if [[ -z "$src" ]]; then
        error "No source specified, aborting"
    elif [[ -z "$dst" ]]; then
        error "No destination specified, aborting"
    fi

    if [[ ! -z "$DEBUG" ]]; then
        debug "src directory is: $src"
        debug "dst file is: $dst"
        debug "index file is: $idx"
        debug "split is: $split"
    fi

    # prepare command
    local IFS=' '
    local tar_opts=( --exclude-from="$EXCLUDE_FILE" )
    if [[ ! -z "$idx" ]]; then
        local tar_opts+=( --listed-incremental="$idx" )
    fi
    local tar_opts+=( --xattrs --numeric-owner --atime-preserve --create --preserve-permissions --bzip2 )
    if [[ -z "$split" ]]; then
        local tar_opts+=( --verbose --verbose --file="$dst" )
    fi
    local tar_opts+=( -C "$src" . )

    local split_opts=(  )
    if [[ ! -z "$split" ]]; then
        local split_opts+=( --bytes="$split" --suffix-length="$SUFFIX_LEN")
    fi

    local cmd_tar=( tar "${tar_opts[@]}" )
    local cmd_split=( split "${split_opts[@]}" - "$dst." )

    if [[ ! -z "$DEBUG" ]]; then
        debug "tar cmd: ${cmd_tar[@]}"
        debug "split cmd: ${cmd_split[@]}"
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
    if [[ ! -z "$idx" ]]; then
        if [[ ! -z "$(grep "^$idx:.*$" "$MASTER_INDEX")" ]]; then
            local idx_sed="$(sanitize_sed "$idx")"
            local dst_sed="$(sanitize_sed "$dst")"
            if [[ ! -z "$DEBUG" ]]; then
                debug "sed regex: /^$idx_sed:/ s/$/ $dst_sed/"
            fi
            sed -i "/^$idx_sed:/ s/$/ $dst_sed/" "$MASTER_INDEX"
        else
            echo "$idx: $dst" >> "$MASTER_INDEX"
        fi
    fi
}

restore_ign_idx() {
    local src="$(sanitize_paths "$1")"
    local dst="$(sanitize_paths "$2")"
    local idx="$(sanitize_paths "$3")"
    local split=

    if [[ -z "$src" ]]; then
        error "No source specified, aborting"
    elif [[ -z "$dst" ]]; then
        error "No destination specified, aborting"
    fi

    if [[ -f "$src" ]]; then
        local split=
    else
        if ls "$src."* 1> /dev/null 2>&1; then
            split=true
        else
            error "Archive does not exist!"
        fi
    fi

    local IFS=' '
    local cat_opts=( "$src."* )
    local tar_opts=(  )
    if [[ ! -z "$idx" ]]; then
        local tar_opts+=( --listed-incremental=/dev/null )
    fi
    local tar_opts+=( --xattrs --numeric-owner --atime-preserve --extract --preserve-permissions --bzip2)
    if [[ -z "$split" ]]; then
        local tar_opts+=( --verbose --verbose --file="$src" )
    fi
    local tar_opts+=( --directory="$dst" )

    local cmd_cat=( cat "${cat_opts[@]}" )
    local cmd_tar=( tar "${tar_opts[@]}" )

    if [[ -z "$split" ]]; then
        "${cmd_tar[@]}"
    else
        "${cmd_cat[@]}" | "${cmd_tar[@]}"
    fi
}

restore() {
    local src="$(sanitize_paths "$1")"
    local dst="$(sanitize_paths "$2")"

    if [[ -z "$src" ]]; then
        error "No source specified, aborting"
    elif [[ -z "$dst" ]]; then
        error "No destination specified, aborting"
    fi

    local restore_order="$(grep "\( \|:\)$src\( \|\$\)" "$MASTER_INDEX")"
    local idx="$(grep -o '^[^:]*' <<< "$restore_order")"
    local idx_sed="$(sanitize_sed "$idx")"
    local restore_order="$(sed "s/$idx_sed://" <<< "$restore_order")"

    echo "$restore_order"
    echo "$idx"

    if [[ -z "$idx" ]]; then
        restore_ign_idx "$src" "$dst"
    else
        read -ra restore_order <<< "$restore_order"
        local rest_order=("${restore_order[@]}")
        unset restore_order
        for arch in "${rest_order[@]}"; do
            restore_ign_idx "$arch" "$dst"
        done

    fi

}

branch() {
    local idx="$(sanitize_paths "$1")"
    local idx_new="$(sanitize_paths "$2")"

    local entry="$(grep "^$idx:" "$MASTER_INDEX")"
    local new_entry="$(grep "^$idx_new:" "$MASTER_INDEX")"

    if [[ -z "$entry" ]]; then
        error "Index does not exist, can't branch, aborting"
    elif [[ ! -z "$new_entry" ]]; then
        error "New index does already exist, would generate duplicate entry, aborting"
    fi

    local idx_sed="$(sanitize_sed "$idx")"
    local idx_new_sed="$(sanitize_sed "$idx_new")"
    local entry="$(sed "s/$idx_sed/$idx_new_sed/" <<< "$entry")"
    echo "$entry" >> "$MASTER_INDEX"
    cp "$idx" "$idx_new"
}

generate_filename() {
    local type_name="$1"
    printf 'b%s_%s,%s' "$type_name" $(date -Iseconds) $(date +%V.%u)
}

match_existing_files() {
    local match_string="$1"
    local type_name="$2"

    local IFS=' '
    local arr_names=( TN % YYYY MM DD hh mm ss TZ CW WD self)
    local arr_subs=( "$type_name" % $(date '+%Y %m %d %H %M %S %:z %V %u') "$(generate_filename "$type_name")" )

    local IFS=$'\n'
    for ((i=0; i<${#arr_names[@]}; i++)); do
        local match_string="$(sed "s/%${arr_names[$i]}/${arr_subs[$i]}/" <<< "$match_string")"
    done

    find "$BACKUP_DIR" -type f -regextype sed -regex "\(.*/\|^\)$match_string.*" -exec basename {} \;
}

match_name() {
    local match_string="$1"
    local type_name="$2"

    local IFS=' '
    local arr_names=( TN % YYYY MM DD hh mm ss TZ CW WD )
    local arr_subs=( "$type_name" % $(date '+%Y %m %d %H %M %S %:z %V %u') )

    local IFS=$'\n'
    for ((i=0; i<${#arr_names[@]}; i++)); do
        local match_string="$(sed "s/%${arr_names[$i]}/${arr_subs[$i]}/" <<< "$match_string")"
    done

    local name="$(generate_filename "$type_name")"

    local match_string="^$match_string\$"
    if [[ "$name" =~ $match_string ]]; then
        echo "$name"
    fi
}

create_backup() {
    local filename="$1"
    local l0backup="$2"
    local directory="$3"

    echo "Backing up $directory to $filename"
    if [[ ! -z "$l0backup" ]]; then
        echo "Backup l0 dump is: $l0backup"
    fi

    local idx=
    if [[ ! -z "$l0backup" ]]; then
        local idx="$l0backup.svnr"
    fi

    if [[ ! -z "$idx" ]]; then
        branch "$SNAPSHOT_DIR/$idx" "$SNAPSHOT_DIR/$filename.svnr"
    fi

    echo "archive: $BACKUP_DIR/$filename.tar.bz2"
    echo "index:   $SNAPSHOT_DIR/$filename.svnr"
    archive "$directory" "$BACKUP_DIR/$filename.tar.bz2" "$SNAPSHOT_DIR/$filename.svnr"
}

managed_cycle() {
    local entry_name=
    local type=
    local incremental_match_base=
    local incremental_match_base_alt=
    local match_exist_name=
    local match_name=
    local directory=

    local IFS=$'\n'
    while read line; do

        # comments are '#' trim them and if the line is empty skip it (this also gets rid of trailing newlines).
        local line="$(sed 's/#.*//' <<< "$line")"
        if [[ -z "$line" ]]; then
            continue
        fi
        local var_val=
        local old_IFS="$IFS"
        local IFS=$'\t''= ' # we don't want trailing or leading spaces/tabs
        read -ra var_val <<< "$line"
        local IFS="$old_IFS"


        # is the current line a tag? [XXXX]
        # if so the previous tag has been filled with all needed variables.
        if [[ ${#var_val[@]} = 1 ]] && [[ "${var_val[0]}" =~ \[..*\] ]]; then
            # handle the entry, it has already been read in
            if [[ "$entry_name" =~ ..* ]]; then
                echo "Checking target: $entry_name"

                local match_exists_name_ss="$(match_existing_files "$match_exist_name" "$entry_name")"
                local match_name_ss="$(match_name "$match_name" "$entry_name")"
                local match_exist_name_s=( $match_exists_name_ss )
                local match_name_s="$match_name_ss"

                # echo "match_exist_name_ss"
                # printf '%s\n' "$match_exists_name_ss"
                # echo "match_exist_name_s"
                # printf '[%s]\n' "${match_exist_name_s[@]}"
                # echo "match_name_s"
                # printf '%s\n' "$match_name_s"

                # check backup conditions and perform backup
                if [[ ${#match_exist_name_s[@]} = 0 ]] && [[ ! -z "$match_name_s" ]]; then
                    echo "No prohibiting files found (checked against $match_exist_name)"
                    echo "Backup file will be: $match_name_s"

                    # if the type is incremental, determine the correct l0 dump
                    local l0back=
                    if [[ "$type" = incremental ]]; then
                        local l0back="$(match_existing_files "$incremental_match_base" "$entry_name")"
                        IFS=$'\n'
                        local l0back=( $(sort -t'_' -k2 <<< "${l0back[*]}" | tac) )
                        local l0back="$(sed 's/\.tar\..*$//' <<< "${l0back[0]}")"
                    fi
                    create_backup "$match_name_s" "$l0back" "$directory"
                else
                    echo "Backup requirements already satisfied, nothing to do"
                fi
            fi

            # start reading of new entry
            local entry_name="$(tr -d '\]\[' <<< "${var_val[0]}")"
            local type=
            local incremental_match_base=
            local incremental_match_base_alt=
            local match_exist_name=
            local match_name=
            local directory=
            continue
        fi
        local "${var_val[0]}"="${var_val[1]}"
    done < "$RULES_CONF"
}

unset IFS
"$@"
