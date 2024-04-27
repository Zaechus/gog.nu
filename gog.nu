#!/usr/bin/env nu
let client_id = "46899977096215655"
let redirect_uri = "https://embed.gog.com/on_login_success?origin=client" | url encode
let client_secret = "9d85c43b1482497dbbce61f6e4aa173a433796eeae2ca8c5f6129f2dc4de46d9"

let token_path = $nu.home-path | path join .cache/gog.nu
let token_file = $token_path | path join .token.json

# get a login code for generating an auth token
def "main login" [] {
  let response_type = "code"
  let layout = "client2"

  echo $'https://auth.gog.com/auth?client_id=($client_id)&redirect_uri=($redirect_uri)&response_type=($response_type)&layout=($layout)'
}

# generate a new auth token
def "main token new" [code: string] {
  mkdir $token_path
  http get --raw $'https://auth.gog.com/token?client_id=($client_id)&client_secret=($client_secret)&grant_type=authorization_code&code=($code)&redirect_uri=($redirect_uri)' | save -f $token_file
  chmod 600 $token_file
}

# refresh the auth token
def "main token refresh" [] {
  http get --raw $'https://auth.gog.com/token?client_id=($client_id)&client_secret=($client_secret)&grant_type=refresh_token&refresh_token=(open $token_file | get refresh_token)&redirect_uri=($redirect_uri)' | save -f $token_file
  chmod 600 $token_file
}

# download offline installers
def "main download" [
  ...search: string
  --id: string # install using the game id
] {
  if ((ls $token_file | get 0.modified) - (date now)) > (open $token_file | get expires_in | into duration -u sec) {
    main token refresh
  }

  let search = $search | str join ' '
  let results = http get --headers [Authorization $'Bearer (open $token_file | get access_token)'] $'https://embed.gog.com/account/getFilteredProducts?mediaType=1&search=($search)' | get products | select id title
  let gameid = if $id != null {
    $id
  } else if ($results | length) > 1 {
    return $results
  } else if ($results | length) == 0 {
    return "No matches."
  } else {
    $results.0.id
  }

  let response = http get --headers [Authorization $'Bearer (open $token_file | get access_token)'] $'https://embed.gog.com/account/gameDetails/($gameid).json'

  for download in $response.downloads {
    if 'English' in $download {
      let urls = if 'linux' in $download.1 {
        $download.1.linux.manualUrl
      } else if 'windows' in $download.1 {
        $download.1.windows.manualUrl
      } else {
        continue
      }

      for url in $urls {
        echo $'Downloading https://gog.com($url)'
        let location = http head --redirect-mode manual --headers [Authorization $'Bearer (open $token_file | get access_token)'] $'https://embed.gog.com($url)' | where name == "location" | get 0.value
        http get --headers [Authorization $'Bearer (open $token_file | get access_token)'] $location | save -p ($location | url parse | get params.path | path basename)
      }
    }
  }
}

# extract a gog installer with innoextract
def "main extract" [file: string] {
  innoextract -gm --default-language en-US -d ($file | str replace -ra '^setup_|_\..*_|_?\(.*\)|\.exe$' '') $file
}

# remove useless gog files from a directory
def "main clean" [dir?: string] {
  if $dir != null {
    cd $dir
  }
  rm -rf goggame-*.* DOSBOX __redist app commonappdata Customer_support.htm webcache.zip
}

def main [] {
  nu $env.CURRENT_FILE --help
}
