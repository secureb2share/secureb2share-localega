#!/usr/bin/env python3
# -*- coding: utf-8 -*-

'''
Send message to the local broker when a file is uploaded.
The message includes filesize and checksum.
'''

# This is helping the helpdesk on the Central EGA side.

import sys
import logging
import os
import asyncio
import uvloop
asyncio.set_event_loop_policy(uvloop.EventLoopPolicy())

host = '127.0.0.1'
port = 8888
delim = b'$'

from .conf import CONF
from .utils.amqp import get_connection, publish
from .utils.checksum import calculate, supported_algorithms

LOG = logging.getLogger(__name__)

class Forwarder(asyncio.Protocol):

    buf = b''

    def __init__(self, broker, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.channel = broker.channel()
        self.inbox_location = CONF.get_value('inbox', 'location', raw=True)
        self.isolation = CONF.get_value('inbox', 'chroot_sessions', conv=bool)
        if self.isolation:
            LOG.info('Using chroot isolation')
        self.checksums_rkey = 'files.inbox.checksums' #CONF.get_value('inbox', 'checksum_routing_key', default='files.inbox.checksums')
        self.inbox_rkey = 'files.inbox' #CONF.get_value('inbox', 'inbox_routing_key', default='files.inbox')

    def connection_made(self, transport):
        peername = transport.get_extra_info('peername')
        LOG.debug('Connection from {}'.format(peername))
        self.transport = transport

    # Buffering can concatenate multiple messages, especially if they arrive too quickly
    # We tried to use TCP_NODELAY (to turn off the socket buffering on the sender's side)
    # but that didn't help. Therefore we use an out-of-band method:
    # We separate messages with a delim character
    def parse(self, data):
        while True:
            if data.count(delim) < 2:
                self.buf = data
                return
            # We have 2 bars
            pos1 = data.find(delim)
            username = data[:pos1]
            pos2 = data.find(delim,pos1+1)
            filename = data[pos1+1:pos2]
            yield (username.decode(),filename.decode())
            data = data[pos2+1:]

    def data_received(self, data):
        if self.buf:
            data = self.buf + data
        for username, filename in self.parse(data):
            try:
                LOG.info("User %s uploaded %s", username, filename)
                self.send_message(username, filename)
            except Exception as e:
                LOG.error("Error notifying upload: %s", e)

    def send_message(self, username, filename):
        inbox = self.inbox_location % username
        if self.isolation:
            filepath = os.path.join(inbox, filename.lstrip('/'))
        else:
            filepath = filename
            filename = filename[len(inbox):]  # there is surelt better
        LOG.debug("Filepath %s", filepath)
        msg = { 'user': username, 'filepath': filename }
        if filename.endswith(supported_algorithms()):
            routing_key = self.checksums_rkey
            with open(filepath, 'rt', encoding='utf-8') as f:
                msg['content'] = f.read()
        else:
            routing_key = self.inbox_rkey
            msg['filesize'] = os.stat(filepath).st_size
            c = calculate(filepath, 'md5')
            if c:
                msg['encrypted_integrity'] = {'algorithm': 'md5', 'checksum': c}
        # Sending
        publish(msg, self.channel, 'cega', routing_key)

    def connection_lost(self, exc):
        if self.buf:
            LOG.error('Ignoring data still in transit: %s', self.buf)
        LOG.debug('Closing the connection')
        self.transport.close()


def main(args=None):
    if not args:
        args = sys.argv[1:]

    CONF.setup(args)  # re-conf

    loop = asyncio.get_event_loop()
    broker = get_connection('broker')
    server = loop.run_until_complete(loop.create_server(lambda: Forwarder(broker), host, port))

    # Serve requests until Ctrl+C is pressed
    LOG.info('Serving on %s', host)
    try:
        loop.run_forever()
    except KeyboardInterrupt:
        LOG.info('Server interrupted')
        broker.close()
    except Exception as e:
        LOG.critical(f'Error {e}')

    # Close the server
    server.close()
    loop.run_until_complete(server.wait_closed())
    loop.close()


if __name__ == '__main__':
    main()
