#!/bin/bash

# Get/set environment
KOVRI_DIR=${KOVRI_DIR:-"/tmp/kovri"}

# Set constants
workspace=${KOVRI_DIR}/build/testnet

docker_image="kovrid"
docker_base_name="kovritestnet"

pid="1000"
gid="1000"

#Note: sequence limit [2:254]
sequence="seq -f "%03g" 10 29"

#Note: this can avoid to rebuild the docker image
#custom_build_dir="-v /home/user/kovri:/kovri"

reseed_file="reseed.zip"

PrintUsage()
{
  echo "Usage: $ export KOVRI_DIR=\"path to your kovri repo\" && $0 {create|start|stop|destroy}" >&2
}

if [ "$#" -ne 1 ]
then
  PrintUsage
  exit 1
fi

Create()
{
  # Ensure repo
  if [[ ! -d $KOVRI_DIR ]]; then
    false
    catch "Kovri not found. See building instructions."
  fi

  # Ensure workspace
  if [[ ! -d $workspace ]]; then
    echo "$workspace does not exist, creating"
    mkdir -p $workspace 2>/dev/null
    catch "Could not create workspace"
  fi

  pushd $workspace

  ## Create RIs
  for _seq in $($sequence); do
    # Setup router dir
    local _dir="router_${_seq}"

    # Create data dir
    mkdir -p ${_dir}/.kovri
    catch "Could not create data dir"

    # Set permissions
    chown -R ${pid}:${gid} ${workspace}/${_dir}
    catch "Could not set ownership ${pid}:${gid}"

    # Run Docker
    docker run -w /home/kovri -it --rm \
      -v ${workspace}/${_dir}:/home/kovri \
      $custom_build_dir \
      $docker_image  /kovri/build/kovri-util routerinfo --create \
        --host=172.18.0.$((10#${_seq})) --port 10${_seq} --floodfill 1 --bandwidth P
    catch "Docker could not run"
  done

  ## ZIP RIs to create unsigned reseed file
  # TODO(unassigned): ensure the zip binary is available
  local _tmp="tmp"
  mkdir $_tmp \
    && cp $(ls router_*/routerInfo* | grep -v key) $_tmp \
    && cd $_tmp \
    && zip $reseed_file * \
    && mv $reseed_file $workspace \
    && cd .. \
    && rm -rf ${workspace}/${_tmp}
  catch "Could not ZIP RI's"

  ## Create docker private network
  docker network create --subnet=172.18.0.0/16 privatenet
  catch "Docker could not create network"

  for _seq in $($sequence)
  do
    ## Create data-dir
    cp -r ${KOVRI_DIR}/pkg kovri_${_seq} && mkdir kovri_${_seq}/core
    catch "Could not copy package resources / create data-dir"

    ## Default with 1 server tunnel
    echo "\
[MyServer]
type = server
address = 127.0.0.1
port = 2222
in_port = 2222
keys = server-keys.dat
;white_list =
;black_list =
" > kovri_${_seq}/config/tunnels.conf
    catch "Could not create server tunnel"

    ## Put RI + key in correct location
    cp $(ls router_${_seq}/routerInfo*.dat) kovri_${_seq}/core/router.info
    cp $(ls router_${_seq}/routerInfo*.key) kovri_${_seq}/core/router.keys
    catch "Could not copy RI and key"

    chown -R ${pid}:${gid} kovri_${_seq}
    catch "Could not set ownership ${pid}:${gid}"

    ## Create container
    docker create -u 0 -w /home/kovri \
      --name ${docker_base_name}_${_seq} \
      --hostname ${docker_base_name}_${_seq} \
      --net privatenet \
      --ip 172.18.0.$((10#${_seq})) \
      -p 10${_seq}:10${_seq} \
      -v ${workspace}:/home/kovri/testnet \
      $custom_build_dir \
      $docker_image /kovri/build/kovri \
      --data-dir /home/kovri/testnet/kovri_${_seq} \
      --log-level 5 \
      --host 172.18.0.$((10#${_seq})) \
      --port 10${_seq} \
      --floodfill=1 \
      --enable-ntcp=0 \
      --disable-su3-verification=1 \
      --reseed-from /home/kovri/testnet/${reseed_file}
    catch "Docker could not create container"
  done
  popd
}

Start()
{
  for _seq in $($sequence); do
    docker start ${docker_base_name}_${_seq}
    catch "Could not start docker: $_seq"
  done
}

Stop()
{
  for _seq in $($sequence); do
    docker stop ${docker_base_name}_${_seq}
    catch "Could not stop docker: $_seq"
  done
}

Destroy()
{
  # TODO(unassigned): error handling?
  for _seq in $($sequence); do
    docker stop ${docker_base_name}_${_seq}
    docker rm -v ${docker_base_name}_${_seq}
    rm -rf ${workspace}/router_${_seq}
    rm -rf ${workspace}/kovri_${_seq}
  done
  rm ${workspace}/${reseed_file}
  docker network rm privatenet
}

# Error handler
catch()
{
  if [[ $? -ne 0 ]]; then
    echo "$1" >&2
    exit 1
  fi
}

case "$1" in
  create)
    Create;;
  start)
    Start;;
  stop)
    Stop;;
  destroy)
    Destroy;;
  *)
    PrintUsage
    exit 1
esac
