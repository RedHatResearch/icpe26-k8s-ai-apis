FROM registry.access.redhat.com/ubi10/ubi:10.0-1758699521
RUN dnf install -y --nodocs https://dl.fedoraproject.org/pub/epel/epel-release-latest-10.noarch.rpm
RUN dnf install -y --nogpgcheck https://mirrors.rpmfusion.org/free/el/rpmfusion-free-release-10.noarch.rpm
RUN dnf update -y && dnf install -y python3-pip ffmpeg
RUN pip install -U openai-whisper
~                                    
