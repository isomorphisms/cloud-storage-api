/**
 * Google-side ZIP extraction helper for cloud-storage-api.
 *
 * Deploy this project as an Apps Script API Executable. The shell client calls
 * unzip_drive_file through scripts.run, so the ZIP never has to be downloaded
 * to the phone/tablet/host that requested the operation.
 */

const RECEIPT_PREFIX = '.cloud-storage-api-unzip-';

function unzip_drive_file(zip_file_id, destination_folder_id) {
  require_nonempty_string(zip_file_id, 'zip_file_id');

  const source = DriveApp.getFileById(zip_file_id);
  const destination = destination_folder_id
    ? DriveApp.getFolderById(destination_folder_id)
    : first_parent_or_root(source);

  const base_name = source.getName().replace(/\.zip$/i, '');
  const output_name = base_name + ' (extracted)';
  const output = unique_folder(destination, output_name);
  const receipt = unique_receipt(
    output,
    RECEIPT_PREFIX + zip_file_id + '.ndjson'
  );

  const run_id = new Date().toISOString();
  append_receipt(receipt, {
    kind: 'run_start',
    run_id: run_id,
    source_file_id: source.getId(),
    source_name: source.getName(),
    destination_folder_id: destination.getId(),
    output_folder_id: output.getId()
  });

  const folder_cache = {'': output};
  const members = Utilities.unzip(source.getBlob());
  let created_files = 0;
  let reused_files = 0;

  members.forEach(function (member) {
    const original_name = member.getName();
    const normalized = safe_archive_path(original_name);
    if (normalized === '') {
      return;
    }

    const directory_entry = /\/$/.test(normalized);
    const path = directory_entry
      ? normalized.replace(/\/+$/, '')
      : normalized;

    if (directory_entry) {
      folder_for_path(output, path, folder_cache);
      append_receipt(receipt, {
        kind: 'directory',
        run_id: run_id,
        path: path
      });
      return;
    }

    const slash = path.lastIndexOf('/');
    const parent_path = slash < 0 ? '' : path.slice(0, slash);
    const name = slash < 0 ? path : path.slice(slash + 1);
    const parent = folder_for_path(output, parent_path, folder_cache);

    const result = create_or_reuse_file(parent, name, member);
    if (result.status === 'created') {
      created_files += 1;
    } else {
      reused_files += 1;
    }

    append_receipt(receipt, {
      kind: 'file',
      run_id: run_id,
      status: result.status,
      path: path,
      file_id: result.file_id,
      size: result.size,
      sha256: result.sha256
    });
  });

  const result = {
    run_id: run_id,
    source_file_id: source.getId(),
    output_folder_id: output.getId(),
    output_folder_url: output.getUrl(),
    receipt_file_id: receipt.getId(),
    receipt_file_url: receipt.getUrl(),
    members: members.length,
    created_files: created_files,
    reused_files: reused_files,
    folders_touched: Object.keys(folder_cache).length - 1,
    source_deleted: false
  };

  append_receipt(receipt, Object.assign({kind: 'run_complete'}, result));
  return result;
}

function require_nonempty_string(value, name) {
  if (typeof value !== 'string' || value.length === 0) {
    throw new Error(name + ' must be a nonempty string');
  }
}

function first_parent_or_root(file) {
  const parents = file.getParents();
  return parents.hasNext() ? parents.next() : DriveApp.getRootFolder();
}

function unique_folder(parent, name) {
  const matches = parent.getFoldersByName(name);
  if (!matches.hasNext()) {
    return parent.createFolder(name);
  }

  const folder = matches.next();
  if (matches.hasNext()) {
    throw new Error(
      'ambiguous output: more than one folder named "' + name + '"'
    );
  }
  return folder;
}

function unique_receipt(folder, name) {
  const matches = folder.getFilesByName(name);
  if (!matches.hasNext()) {
    return folder.createFile(name, '', MimeType.PLAIN_TEXT);
  }

  const file = matches.next();
  if (matches.hasNext()) {
    throw new Error(
      'ambiguous receipt: more than one file named "' + name + '"'
    );
  }
  return file;
}

function safe_archive_path(name) {
  let path = String(name).replace(/\\/g, '/');

  if (path === '') {
    return '';
  }
  if (path[0] === '/' || /^[A-Za-z]:/.test(path)) {
    throw new Error('absolute archive path rejected: ' + path);
  }

  const directory_entry = /\/$/.test(path);
  path = path.replace(/\/+$/, '');
  if (path === '') {
    return '';
  }

  const parts = path.split('/');
  parts.forEach(function (part) {
    if (part === '' || part === '.' || part === '..') {
      throw new Error('unsafe archive path rejected: ' + name);
    }
  });

  return parts.join('/') + (directory_entry ? '/' : '');
}

function folder_for_path(root, path, cache) {
  if (path === '') {
    return root;
  }
  if (Object.prototype.hasOwnProperty.call(cache, path)) {
    return cache[path];
  }

  const parts = path.split('/');
  let current = root;
  let current_path = '';

  parts.forEach(function (part) {
    current_path = current_path === '' ? part : current_path + '/' + part;
    if (Object.prototype.hasOwnProperty.call(cache, current_path)) {
      current = cache[current_path];
      return;
    }

    current = unique_folder(current, part);
    cache[current_path] = current;
  });

  return current;
}

function create_or_reuse_file(parent, name, member) {
  const incoming_bytes = member.getBytes();
  const incoming_sha256 = sha256_hex(incoming_bytes);
  const matches = parent.getFilesByName(name);

  if (!matches.hasNext()) {
    const blob = member.copyBlob().setName(name);
    const file = parent.createFile(blob);
    return {
      status: 'created',
      file_id: file.getId(),
      size: incoming_bytes.length,
      sha256: incoming_sha256
    };
  }

  const existing = matches.next();
  if (matches.hasNext()) {
    throw new Error(
      'ambiguous existing file: more than one file named "' + name + '"'
    );
  }

  const existing_bytes = existing.getBlob().getBytes();
  const existing_sha256 = sha256_hex(existing_bytes);
  if (
    existing_bytes.length !== incoming_bytes.length ||
    existing_sha256 !== incoming_sha256
  ) {
    throw new Error(
      'existing file conflicts with archive member: ' + name
    );
  }

  return {
    status: 'reused',
    file_id: existing.getId(),
    size: existing_bytes.length,
    sha256: existing_sha256
  };
}

function sha256_hex(bytes) {
  const digest = Utilities.computeDigest(
    Utilities.DigestAlgorithm.SHA_256,
    bytes
  );
  return digest.map(function (value) {
    const unsigned = value < 0 ? value + 256 : value;
    return ('0' + unsigned.toString(16)).slice(-2);
  }).join('');
}

function append_receipt(file, record) {
  const previous = file.getBlob().getDataAsString();
  const line = JSON.stringify(record) + '\n';
  file.setContent(previous + line);
}
