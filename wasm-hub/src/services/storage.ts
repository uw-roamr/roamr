import {
  ref,
  uploadBytesResumable,
  getDownloadURL,
  deleteObject,
  UploadTaskSnapshot,
} from 'firebase/storage';
import { storage } from '../config/firebase';

const WASM_MAGIC_NUMBER = new Uint8Array([0x00, 0x61, 0x73, 0x6d]);
const MAX_FILE_SIZE = 50 * 1024 * 1024; // 50MB

export interface UploadProgress {
  bytesTransferred: number;
  totalBytes: number;
  percentage: number;
}

export function validateWasmFile(file: File): { valid: boolean; error?: string } {
  if (file.size > MAX_FILE_SIZE) {
    return { valid: false, error: 'File size exceeds 50MB limit.' };
  }

  if (!file.name.endsWith('.wasm')) {
    return { valid: false, error: 'File must have .wasm extension.' };
  }

  return { valid: true };
}

export async function validateWasmMagicNumber(file: File): Promise<{ valid: boolean; error?: string }> {
  return new Promise((resolve) => {
    const reader = new FileReader();
    reader.onload = (e) => {
      const buffer = e.target?.result as ArrayBuffer;
      const bytes = new Uint8Array(buffer.slice(0, 4));

      const isValidWasm = bytes.every((byte, index) => byte === WASM_MAGIC_NUMBER[index]);

      if (!isValidWasm) {
        resolve({ valid: false, error: 'Invalid WASM file format.' });
      } else {
        resolve({ valid: true });
      }
    };
    reader.onerror = () => resolve({ valid: false, error: 'Failed to read file.' });
    reader.readAsArrayBuffer(file.slice(0, 4));
  });
}

export function uploadWasmFile(
  file: File,
  userId: string,
  fileId: string,
  onProgress?: (progress: UploadProgress) => void
): Promise<{ url: string; path: string }> {
  return new Promise((resolve, reject) => {
    const storagePath = `wasm-files/${userId}/${fileId}/${file.name}`;
    const storageRef = ref(storage, storagePath);

    const metadata = {
      contentType: 'application/wasm',
      customMetadata: {
        uploaderId: userId,
        originalName: file.name,
      },
    };

    const uploadTask = uploadBytesResumable(storageRef, file, metadata);

    uploadTask.on(
      'state_changed',
      (snapshot: UploadTaskSnapshot) => {
        const percentage = (snapshot.bytesTransferred / snapshot.totalBytes) * 100;
        onProgress?.({
          bytesTransferred: snapshot.bytesTransferred,
          totalBytes: snapshot.totalBytes,
          percentage,
        });
      },
      (error) => {
        reject(error);
      },
      async () => {
        const url = await getDownloadURL(uploadTask.snapshot.ref);
        resolve({ url, path: storagePath });
      }
    );
  });
}

export async function deleteWasmFromStorage(storagePath: string): Promise<void> {
  const storageRef = ref(storage, storagePath);
  await deleteObject(storageRef);
}

export async function getWasmDownloadUrl(storagePath: string): Promise<string> {
  const storageRef = ref(storage, storagePath);
  return getDownloadURL(storageRef);
}

export function formatFileSize(bytes: number): string {
  if (bytes === 0) return '0 B';
  const k = 1024;
  const sizes = ['B', 'KB', 'MB', 'GB'];
  const i = Math.floor(Math.log(bytes) / Math.log(k));
  return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i];
}
