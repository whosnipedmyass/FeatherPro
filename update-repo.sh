#!/bin/sh
# this shouldn't be ran when testing, only when building via workflow

handle_error() {
  echo "Error: $1" >&2
  exit 1
}

REPO="${RELEASE_REPO:-${GITHUB_REPOSITORY:-whosnipedmyass/FeatherPro}}"

echo "Fetching latest release data from GitHub for repo: $REPO..."

# Use Accept header and optional auth to avoid rate limits and access private repos
if [ -n "$GITHUB_TOKEN" ]; then
  release_info=$(curl -s -H "Accept: application/vnd.github.v3+json" -H "Authorization: token $GITHUB_TOKEN" "https://api.github.com/repos/${REPO}/releases/latest")
else
  release_info=$(curl -s -H "Accept: application/vnd.github.v3+json" "https://api.github.com/repos/${REPO}/releases/latest")
fi

# quick sanity check: ensure we have JSON (not HTML or an error page)
if ! echo "$release_info" | jq . >/dev/null 2>&1; then
  echo "Error: received non-JSON response from GitHub API (possible rate limit or auth error)."
  echo "Response excerpt:" 
  echo "$release_info" | sed -n '1,40p'
  exit 1
fi

clean_release_info=$(echo "$release_info" | tr -d '\000-\037')

# only strip a leading "v" if present
version=$(echo "$clean_release_info" | jq -r '.tag_name // empty | if startswith("v") then .[1:] else . end')
updated_at=$(echo "$clean_release_info" | jq -r '.published_at // .created_at // empty')

# fallback if version is empty
if [ -z "$version" ]; then
  version=""
fi

echo "Release version: $version"
echo "Updated at: $updated_at"

ipa_files=$(echo "$clean_release_info" | jq -r '[.assets[]? | select(.name | endswith(".ipa") or endswith(".tipa")) | {
    name: .name,
    size: (.size | tonumber),
    download_url: .browser_download_url
}]')

if [ "$(echo "$ipa_files" | jq 'length')" -gt 0 ]; then
    echo "Found IPA/TIPA files in release:"
    echo "$ipa_files" | jq -r '.[] | "• \(.name) (\(.size) bytes)"'

    JSON_FILE="app-repo.json"
    if [ ! -f "$JSON_FILE" ]; then
        handle_error "$JSON_FILE does not exist."
    fi
    
    cp "$JSON_FILE" "${JSON_FILE}.tmp"
    
    num_apps=$(jq '.apps | length // 0' "$JSON_FILE")
    echo "Repository has $num_apps apps"
    
    # If there are zero apps, do nothing
    if [ "$num_apps" -le 0 ]; then
      echo "No apps to update in $JSON_FILE"
      exit 0
    fi

    for app_index in $(seq 0 $(($num_apps - 1))); do
        app_name=$(jq -r ".apps[$app_index].name" "$JSON_FILE")
        app_id=$(jq -r ".apps[$app_index].bundleIdentifier" "$JSON_FILE")
        
        echo "Processing app[$app_index]: $app_name ($app_id)"
        
        matching_file=""
        
        if echo "$app_name" | grep -i "idevice" > /dev/null; then
            matching_file=$(echo "$ipa_files" | jq -r 'map(select(.name | endswith(".tipa") or contains("idevice"))) | first')
        else
            matching_file=$(echo "$ipa_files" | jq -r 'map(select(.name | endswith(".ipa") and (contains("idevice") | not))) | first')
        fi
        
        if [ "$matching_file" = "null" ] || [ -z "$matching_file" ]; then
            matching_file=$(echo "$ipa_files" | jq -r 'first')
            echo "No specific match found for $app_name, using first available file"
        fi
        
        if [ "$matching_file" != "null" ] && [ -n "$matching_file" ]; then
            name=$(echo "$matching_file" | jq -r '.name')
            size=$(echo "$matching_file" | jq -r '.size')
            download_url=$(echo "$matching_file" | jq -r '.download_url')
            
            echo "Updating $app_name with: $name"
            
            jq --arg index "$app_index" \
               --arg version "$version" \
               --arg date "$updated_at" \
               --argjson size "$size" \
               --arg url "$download_url" \
               --arg name "$name" \
               '.apps[$index | tonumber].version = $version |
                .apps[$index | tonumber].versionDate = $date |
                .apps[$index | tonumber].size = ($size | tonumber) |
                .apps[$index | tonumber].downloadURL = $url |
                .apps[$index | tonumber].versions = [{
                    version: $version,
                    date: $date,
                    size: ($size | tonumber),
                    downloadURL: $url
                }]' "$JSON_FILE" > "${JSON_FILE}.tmp"

            if jq '.' "${JSON_FILE}.tmp" >/dev/null 2>&1; then
                echo "JSON file is valid after update. Proceeding to replace."
                mv "${JSON_FILE}.tmp" "$JSON_FILE"
                rm -f "${JSON_FILE}.tmp"
            else
                echo "Error: JSON file is invalid after update. Restoring backup."
                rm -f "${JSON_FILE}.tmp"
            fi
        else
            echo "No matching file found for $app_name"
        fi
    done
    
    echo "Repository update completed"
else
    echo "No .ipa or .tipa files found in the latest release."
fi
