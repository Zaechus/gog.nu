#!/usr/bin/env nu
let client_id = "46899977096215655"
let redirect_uri = "https://embed.gog.com/on_login_success?origin=client" | url encode
let client_secret = "9d85c43b1482497dbbce61f6e4aa173a433796eeae2ca8c5f6129f2dc4de46d9"

let token_path = $env.FILE_PWD | path join token.json

# get a login code for generating an auth token
def "main login" [] {
  let response_type = "code"
  let layout = "client2"

  echo $'https://auth.gog.com/auth?client_id=($client_id)&redirect_uri=($redirect_uri)&response_type=($response_type)&layout=($layout)'
}

# generate a new auth token
def "main token new" [code: string] {
    http get --raw $'https://auth.gog.com/token?client_id=($client_id)&client_secret=($client_secret)&grant_type=authorization_code&code=($code)&redirect_uri=($redirect_uri)' | save -f $token_path
    chmod 600 $token_path
}

# refresh the auth token
def "main token refresh" [] {
    http get --raw $'https://auth.gog.com/token?client_id=($client_id)&client_secret=($client_secret)&grant_type=refresh_token&refresh_token=(open $token_path | get refresh_token)&redirect_uri=($redirect_uri)' | save -f $token_path
    chmod 600 $token_path
}

# download a offline installers
def "main download" [
  ...search: string
  -f # use the first search result
] {
  let search = $search | str join ' '
  let results = http get --headers [Authorization $'Bearer (open $token_path | get access_token)'] $'https://embed.gog.com/account/getFilteredProducts?mediaType=1&search=($search)' | get products | select id title
  if ($results | length) == 0 {
    return "No matches."
  } else if ($results | length) > 1 and not $f {
    return $results
  }

  let id = $results.0.id
  let response = http get --headers [Authorization $'Bearer (open $token_path | get access_token)'] $'https://embed.gog.com/account/gameDetails/($id).json'

  for download in $response.downloads {
    if 'English' in $download {
      let urls = if 'linux' in $download.1 {
        $download.1.linux.manualUrl
      } else if 'windows' in $download.1 {
        $download.1.windows.manualUrl
      } else {
        return
      }

      for url in $urls {
        echo $'Downloading https://gog.com($url)'
        let location = http head --redirect-mode manual --headers [Authorization $'Bearer (open $token_path | get access_token)'] $'https://embed.gog.com($url)' | where name == "location" | get 0.value
        http get --headers [Authorization $'Bearer (open $token_path | get access_token)'] $location | save -p ($location | url parse | get params.path | path basename)
      }
    }
  }
}

# extract a gog installer with innoextract
def "main extract" [file: string] {
  innoextract -gm -d ($file | str replace -ra '^setup_|_\..*_|_?\(.*\)|\.exe$' '') $file
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
