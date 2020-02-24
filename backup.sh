#!/usr/bin/env bash

SUFFIX_LEN=3
EXCLUDE_FILE=back_exclude.txt
MASTER_INDEX=idx/backups.idx

warn() {
    echo "$1" 1>&2
}

error() {
    warn "Error: $1"
    [[ -z "$2" ]] && exit '-1' || exit "$2"
}

sanitize_sed() {
    sed 's/[\/&]/\\&/' <<< "$1"
}

archive() {
    local src="$1"
    local dst="$2"
    local idx="$3"
    local split="$4"

    if [[ -z "$src" ]]; then
        error "No source specified, aborting"
    elif [[ -z "$dst" ]]; then
        error "No destination specified, aborting"
    fi

    # prepare command
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
    local cmd_split=( split "${split_opts[@]}" - "$dst.")

    # update index database
    # format: every line is one entry, beginning with the index filename followed by a colon (':')
    # after this there is ordered a space seperated list of files which need to be restored.
    if [[ ! -z "$idx" ]]; then
        if [[ -f "$idx" ]]; then
            local idx_sed="$(sanitize_sed "$idx")"
            sed -i "/^$idx_sed:/ s/$/ $dst/" "$MASTER_INDEX"
        else
            echo "$idx: $dst" >> "$MASTER_INDEX"
        fi
    fi

    # archive
    if [[ -z "$split" ]]; then
        "${cmd_tar[@]}"
    else
        "${cmd_tar[@]}" | "${cmd_split[@]}"
    fi
}

restore_ign_idx() {
    local src="$1"
    local dst="$2"
    local idx="$3"
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
    local src="$1"
    local dst="$2"

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
    local idx="$1"
    local idx_new="$2"

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

"$@"
