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
  -n: int # install the nth game result
  --skip-linux # skip checking for linux files
] {
  if ((date now) - (ls $token_file | get 0.modified)) > (open $token_file | get expires_in | into duration -u sec) {
    main token refresh
  }

  let search = $search | str join ' '
  let results = http get --headers [Authorization $'Bearer (open $token_file | get access_token)'] $'https://embed.gog.com/account/getFilteredProducts?mediaType=1&search=($search)' | get products | select id title
  let gameid = if $id != null {
    $id
  } else if $n != null {
    $results.id | get $n
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
      let urls = if not $skip_linux and 'linux' in $download.1 {
        $download.1.linux.manualUrl
      } else if 'windows' in $download.1 {
        $download.1.windows.manualUrl
      } else {
        continue
      }

      for url in $urls {
        echo $'Downloading https://gog.com($url)'
        let location = http head --redirect-mode manual --headers [Authorization $'Bearer (open $token_file | get access_token)'] $'https://embed.gog.com($url)' | where name == "location" | get 0.value
        let filename = $location | url parse | get params.path | path basename
        let tmpfile = $'($filename).tmp'
        http get --headers [Authorization $'Bearer (open $token_file | get access_token)'] $location | save -p $tmpfile
        mv -n $tmpfile $filename
      }
    }
  }
}

# get the folder name for a setup file
def "main name" [file: string] {
  $file | str replace -ra '^(gog|setup)_|_v\d+_.*$|_\d+\-\d+_|_\d*\..*|_?\(.*\)|\.(bin|exe)$|_\d{1}[_.].*\.sh$' '' | str replace -a '_' '-' | str replace -ra '-+' '-'
}

# extract a gog installer with innoextract
def "main extract" [
  file: string
  --no-clean # Do not remove useless files after extraction
] {
  let dir = main name $file
  innoextract -gm --default-language en-US -d $dir $file
  if not $no_clean {
    main clean $dir
  }
}

def mv_support_files [d: string] {
  let dname = ($d | path split | skip 2 | path join)
  let found = (ls ./**/* | where type == dir | find -v __support | find -ir $'^($dname)$' | get name)
  let dest = if ($found | length) > 0 {
    $found.0
  } else {
    $'./($dname)'
  }
  for f in (ls $d) {
    if $f.type == file {
      mv -v $f.name $dest
    } else if $f.type == dir {
      let fname = ($f.name | path split | skip 2 | path join)
      let ffound = (ls $dest | where type == dir | find -ir $'^($fname)$' | get name)
      if ($ffound | length) == 0 {
        mv -v $f.name $dest
      } else {
        mv_support_files $f.name
      }
    }
  }
}

# remove useless gog files from a directory
def "main clean" [dir?: string] {
  if $dir != null {
    cd $dir
  }
  rm -rf goggame-*.* DOSBOX __redist app commonappdata Customer_support.htm webcache.zip gfw_high*.ico gog.ico support.ico

  if ('__support/app' | path exists) {
    rm -f __support/app/dosbox*.conf
    mv_support_files __support/app
  }
  if ('__support/save' | path exists) {
    mv_support_files __support/save
  }
  rm -rf __support
}

def main [] {
  nu $env.CURRENT_FILE --help
}
