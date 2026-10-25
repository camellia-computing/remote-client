import assert from 'node:assert/strict';
import test from 'node:test';

import { hbb } from '../src/proto/generated.js';

test('clipboard file-content codecs preserve unsigned native fields', () => {
  const request = hbb.CliprdrFileContentsRequest.decode(
    hbb.CliprdrFileContentsRequest.encode({
      streamId: 0xffff_ffff,
      listIndex: 0xffff_fffe,
      dwFlags: 2,
      nPositionLow: 0xffff_ffff,
      nPositionHigh: 0xffff_ffff,
      cbRequested: 0xffff_ffff,
      haveClipDataId: true,
      clipDataId: 0xffff_fffd
    }).finish()
  );
  assert.equal(request.streamId, 0xffff_ffff);
  assert.equal(request.listIndex, 0xffff_fffe);
  assert.equal(request.nPositionLow, 0xffff_ffff);
  assert.equal(request.nPositionHigh, 0xffff_ffff);
  assert.equal(request.cbRequested, 0xffff_ffff);
  assert.equal(request.clipDataId, 0xffff_fffd);

  const response = hbb.CliprdrFileContentsResponse.decode(
    hbb.CliprdrFileContentsResponse.encode({
      msgFlags: 0xffff_ffff,
      streamId: 0xffff_fffc,
      requestedData: new Uint8Array([1, 2, 3])
    }).finish()
  );
  assert.equal(response.msgFlags, 0xffff_ffff);
  assert.equal(response.streamId, 0xffff_fffc);
  assert.deepEqual(Array.from(response.requestedData), [1, 2, 3]);
});

test('web file transfer advertises version 2 and preserves byte offsets', () => {
  const login = hbb.LoginRequest.decode(
    hbb.LoginRequest.encode({ fileTransferProtocolVersion: 2 }).finish()
  );
  assert.equal(login.fileTransferProtocolVersion, 2);

  const confirm = hbb.FileTransferSendConfirmRequest.decode(
    hbb.FileTransferSendConfirmRequest.encode(
      hbb.FileTransferSendConfirmRequest.fromObject({
        id: 7,
        fileNum: 1,
        offsetBytes: '4294967297'
      })
    ).finish()
  );
  const object = hbb.FileTransferSendConfirmRequest.toObject(confirm, {
    longs: String,
    oneofs: true
  });
  assert.equal(object.offsetBytes, '4294967297');
  assert.equal(object.union, 'offsetBytes');
});
