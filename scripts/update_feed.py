"""Construct the stable Sparkle update feed URL."""
import argparse


def update_feed_url(repository):
    return f"https://github.com/{repository}/releases/download/update-feed/appcast.xml"


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--repository', required=True)
    print(update_feed_url(parser.parse_args().repository))
