import argparse
import logging
import requests
from pathlib import Path
import zipfile

logging.basicConfig(level=logging.INFO,format='%(levelname)s: %(message)s')

class TimezoneDownloader:
    core_files=['time_zone.csv']
    extra_files=['country.csv','README','database.sql']

    def __init__(self,url:str,output_dir:str):
        self.url=url
        self.output_dir=Path(output_dir)
        self.zip_path=self.output_dir / 'TimeZoneDB.zip'

    def download_zip(self):
        logging.info(f'Downloading from {self.url}')
        response=requests.get(self.url)
        if response.status_code == 200:
            self.output_dir.mkdir(parents=True,exist_ok=True)
            self.zip_path.write_bytes(response.content)
            logging.info(f'Downloaded zip to {self.zip_path}')
        else:
            raise ConnectionError(f'Failed to download file. Status code: {response.status_code}')

    def extract_zip(self):
        if self.zip_path.exists():
            with zipfile.ZipFile(self.zip_path,'r') as zip_ref:
                zip_ref.extractall(self.output_dir)
            self.zip_path.unlink()
            logging.info(f'Extracted zip contents to {self.output_dir}')
        else:
            raise FileNotFoundError(f'Zip file not found: {self.zip_path}')

    def clean_files(self):
        for file_name in self.extra_files:
            file_path=self.output_dir/file_name
            if file_path.exists():
                file_path.unlink()
                logging.info(f'Removed extra file: {file_path}')

    def run(self):
        try:
            self.download_zip()
            self.extract_zip()
            self.clean_files()
            logging.info('Timezone update completed successfully.')
        except Exception as e:
            logging.error(f'Error: {e}')

def main():
    parser=argparse.ArgumentParser(prog='TimezoneDownloader',description='Download and update timezone reference files.')
    parser.add_argument('--fileurl',default='https://timezonedb.com/files/TimeZoneDB.csv.zip',help='URL of the timezone zip file')
    parser.add_argument('--output',help='Directory to save extracted files')
    args=parser.parse_args()

    if not args.output:
        script_dir = Path(__file__).resolve().parent
        args.output = str(script_dir)
        logging.info(f'No output directory provided. Defaulting to script directory: {args.output}')

    downloader=TimezoneDownloader(args.fileurl,args.output)
    downloader.run()

if __name__ == '__main__':
    main()
