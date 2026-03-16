import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { useAuth } from '../contexts/AuthContext';
import {
  getUserWasmFiles,
  updateWasmFile,
  deleteWasmFile,
  decrementUserUploadCount,
  WasmFile,
} from '../services/firestore';
import { deleteWasmFromStorage } from '../services/storage';
import { WasmGrid } from '../components/wasm';
import { Button, Modal } from '../components/ui';
import { useToast } from '../components/ui/Toast';
import styles from './DashboardPage.module.css';

export function DashboardPage() {
  const { user } = useAuth();
  const [files, setFiles] = useState<WasmFile[]>([]);
  const [loading, setLoading] = useState(true);
  const [deleteModal, setDeleteModal] = useState<WasmFile | null>(null);
  const [deleting, setDeleting] = useState(false);
  const { showToast } = useToast();

  useEffect(() => {
    if (!user) return;

    async function fetchUserFiles() {
      try {
        const userFiles = await getUserWasmFiles(user!.uid);
        setFiles(userFiles);
      } catch (error) {
        console.error('Error fetching user files:', error);
        showToast('Failed to load your files', 'error');
      } finally {
        setLoading(false);
      }
    }
    fetchUserFiles();
  }, [user, showToast]);

  const handleToggleVisibility = async (file: WasmFile) => {
    try {
      await updateWasmFile(file.id, { isPublic: !file.isPublic });
      setFiles((prev) =>
        prev.map((f) =>
          f.id === file.id ? { ...f, isPublic: !f.isPublic } : f
        )
      );
      showToast(
        file.isPublic ? 'File is now private' : 'File is now public',
        'success'
      );
    } catch (error) {
      console.error('Error updating visibility:', error);
      showToast('Failed to update visibility', 'error');
    }
  };

  const handleDelete = async () => {
    if (!deleteModal || !user) return;

    setDeleting(true);
    try {
      await deleteWasmFromStorage(deleteModal.storagePath);
      await deleteWasmFile(deleteModal.id);
      await decrementUserUploadCount(user.uid);

      setFiles((prev) => prev.filter((f) => f.id !== deleteModal.id));
      showToast('File deleted successfully', 'success');
      setDeleteModal(null);
    } catch (error) {
      console.error('Error deleting file:', error);
      showToast('Failed to delete file', 'error');
    } finally {
      setDeleting(false);
    }
  };

  return (
    <div className={styles.page}>
      <div className={styles.header}>
        <div>
          <h1 className={styles.title}>My WASM Files</h1>
          <p className={styles.subtitle}>
            Manage your uploaded WebAssembly modules
          </p>
        </div>
        <Link to="/upload">
          <Button>Upload New</Button>
        </Link>
      </div>

      <WasmGrid
        files={files}
        loading={loading}
        showActions
        onToggleVisibility={handleToggleVisibility}
        onDelete={(file) => setDeleteModal(file)}
        emptyMessage="You haven't uploaded any WASM files yet"
      />

      <Modal
        isOpen={!!deleteModal}
        onClose={() => setDeleteModal(null)}
        title="Delete File"
      >
        <div className={styles.deleteModal}>
          <p>
            Are you sure you want to delete <strong>{deleteModal?.name}</strong>?
          </p>
          <p className={styles.warning}>This action cannot be undone.</p>
          <div className={styles.modalActions}>
            <Button
              variant="ghost"
              onClick={() => setDeleteModal(null)}
              disabled={deleting}
            >
              Cancel
            </Button>
            <Button variant="danger" onClick={handleDelete} loading={deleting}>
              Delete
            </Button>
          </div>
        </div>
      </Modal>
    </div>
  );
}
