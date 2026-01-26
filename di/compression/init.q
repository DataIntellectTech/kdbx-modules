/ Load core functionality into root module namespace
\l ::compression.q

/ Load KX log module - needed for log.info and log.error
logger:use`kx.log
log:logger.createLog[]

export:([showcomp;getcompressioncsv;compressmaxage;docompression;getstatstab])
