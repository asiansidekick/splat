# Reconstruction image for the pipeline spike.
# Nerfstudio bundles gsplat (splatfacto) and the Polycam importer.
FROM ghcr.io/nerfstudio-project/nerfstudio:latest

COPY run_spike.sh /usr/local/bin/run_spike.sh
RUN chmod +x /usr/local/bin/run_spike.sh

WORKDIR /data
ENTRYPOINT ["run_spike.sh"]
