import {
  collection,
  doc,
  addDoc,
  updateDoc,
  deleteDoc,
  getDoc,
  getDocs,
  query,
  where,
  orderBy,
  serverTimestamp,
  increment,
  Timestamp,
} from 'firebase/firestore';
import { db } from '../config/firebase';

export interface WasmFile {
  id: string;
  name: string;
  fileName: string;
  description: string;
  uploaderId: string;
  uploaderName: string;
  isPublic: boolean;
  storageUrl: string;
  storagePath: string;
  uploadedAt: Timestamp;
  fileSize: number;
  downloadCount: number;
  tags: string[];
}

export interface CreateWasmFileData {
  name: string;
  fileName: string;
  description: string;
  uploaderId: string;
  uploaderName: string;
  isPublic: boolean;
  storageUrl: string;
  storagePath: string;
  fileSize: number;
  tags: string[];
}

const WASM_FILES_COLLECTION = 'wasmFiles';

export async function createWasmFile(data: CreateWasmFileData): Promise<string> {
  const docRef = await addDoc(collection(db, WASM_FILES_COLLECTION), {
    ...data,
    uploadedAt: serverTimestamp(),
    downloadCount: 0,
  });
  return docRef.id;
}

export async function getWasmFile(id: string): Promise<WasmFile | null> {
  const docRef = doc(db, WASM_FILES_COLLECTION, id);
  const docSnap = await getDoc(docRef);

  if (!docSnap.exists()) {
    return null;
  }

  return { id: docSnap.id, ...docSnap.data() } as WasmFile;
}

export async function getPublicWasmFiles(): Promise<WasmFile[]> {
  const q = query(
    collection(db, WASM_FILES_COLLECTION),
    where('isPublic', '==', true),
    orderBy('uploadedAt', 'desc')
  );

  const querySnapshot = await getDocs(q);
  return querySnapshot.docs.map((doc) => ({
    id: doc.id,
    ...doc.data(),
  })) as WasmFile[];
}

export async function getUserWasmFiles(userId: string): Promise<WasmFile[]> {
  const q = query(
    collection(db, WASM_FILES_COLLECTION),
    where('uploaderId', '==', userId),
    orderBy('uploadedAt', 'desc')
  );

  const querySnapshot = await getDocs(q);
  return querySnapshot.docs.map((doc) => ({
    id: doc.id,
    ...doc.data(),
  })) as WasmFile[];
}

export async function updateWasmFile(
  id: string,
  data: Partial<Pick<WasmFile, 'name' | 'description' | 'isPublic' | 'tags'>>
): Promise<void> {
  const docRef = doc(db, WASM_FILES_COLLECTION, id);
  await updateDoc(docRef, data);
}

export async function deleteWasmFile(id: string): Promise<void> {
  const docRef = doc(db, WASM_FILES_COLLECTION, id);
  await deleteDoc(docRef);
}

export async function incrementDownloadCount(id: string): Promise<void> {
  const docRef = doc(db, WASM_FILES_COLLECTION, id);
  await updateDoc(docRef, {
    downloadCount: increment(1),
  });
}

export async function incrementUserUploadCount(userId: string): Promise<void> {
  const docRef = doc(db, 'users', userId);
  await updateDoc(docRef, {
    uploadCount: increment(1),
  });
}

export async function decrementUserUploadCount(userId: string): Promise<void> {
  const docRef = doc(db, 'users', userId);
  await updateDoc(docRef, {
    uploadCount: increment(-1),
  });
}
