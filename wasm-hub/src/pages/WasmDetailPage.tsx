import { useEffect, useState } from 'react';
import { useParams, useNavigate, Link } from 'react-router-dom';
import { useAuth } from '../contexts/AuthContext';
import {
  getWasmFile,
  incrementDownloadCount,
  WasmFile,
} from '../services/firestore';
import { formatFileSize } from '../services/storage';
import { Button } from '../components/ui';
import { useToast } from '../components/ui/Toast';
import styles from './WasmDetailPage.module.css';

export function WasmDetailPage() {
  const { id } = useParams<{ id: string }>();
  const { user } = useAuth();
  const navigate = useNavigate();
  const { showToast } = useToast();

  const [file, setFile] = useState<WasmFile | null>(null);
  const [loading, setLoading] = useState(true);
  const [downloading, setDownloading] = useState(false);

  useEffect(() => {
    async function fetchFile() {
      if (!id) return;

      try {
        const wasmFile = await getWasmFile(id);

        if (!wasmFile) {
          showToast('File not found', 'error');
          navigate('/browse');
          return;
        }

        if (!wasmFile.isPublic && wasmFile.uploaderId !== user?.uid) {
          showToast('You do not have access to this file', 'error');
          navigate('/browse');
          return;
        }

        setFile(wasmFile);
      } catch (error) {
        console.error('Error fetching file:', error);
        showToast('Failed to load file details', 'error');
      } finally {
        setLoading(false);
      }
    }

    fetchFile();
  }, [id, user, navigate, showToast]);

  const handleDownload = async () => {
    if (!file) return;

    setDownloading(true);
    try {
      // Use the stored URL directly - browsers will download .wasm files
      const url = file.storageUrl;
      window.open(url, '_blank');

      await incrementDownloadCount(file.id);
      setFile((prev) =>
        prev ? { ...prev, downloadCount: prev.downloadCount + 1 } : null
      );

      showToast('Download started', 'success');
    } catch (error) {
      console.error('Download error:', error);
      showToast('Failed to download file', 'error');
    } finally {
      setDownloading(false);
    }
  };

  if (loading) {
    return (
      <div className={styles.loading}>
        <div className={styles.spinner} />
        <p>Loading...</p>
      </div>
    );
  }

  if (!file) {
    return (
      <div className={styles.notFound}>
        <p>File not found</p>
        <Link to="/browse">
          <Button>Browse Files</Button>
        </Link>
      </div>
    );
  }

  const uploadDate = file.uploadedAt?.toDate?.()
    ? file.uploadedAt.toDate().toLocaleDateString('en-US', {
        year: 'numeric',
        month: 'long',
        day: 'numeric',
      })
    : 'Unknown';

  const isOwner = user?.uid === file.uploaderId;

  return (
    <div className={styles.page}>
      <div className={styles.card}>
        <div className={styles.header}>
          <div className={styles.icon}>📦</div>
          <div className={styles.headerContent}>
            <h1 className={styles.name}>{file.name}</h1>
            <p className={styles.fileName}>{file.fileName}</p>
          </div>
          <Button onClick={handleDownload} loading={downloading}>
            Download
          </Button>
        </div>

        <div className={styles.meta}>
          <div className={styles.metaItem}>
            <span className={styles.metaLabel}>Size</span>
            <span className={styles.metaValue}>{formatFileSize(file.fileSize)}</span>
          </div>
          <div className={styles.metaItem}>
            <span className={styles.metaLabel}>Downloads</span>
            <span className={styles.metaValue}>{file.downloadCount}</span>
          </div>
          <div className={styles.metaItem}>
            <span className={styles.metaLabel}>Uploaded</span>
            <span className={styles.metaValue}>{uploadDate}</span>
          </div>
          <div className={styles.metaItem}>
            <span className={styles.metaLabel}>Visibility</span>
            <span className={`${styles.metaValue} ${file.isPublic ? styles.public : styles.private}`}>
              {file.isPublic ? 'Public' : 'Private'}
            </span>
          </div>
        </div>

        {file.description && (
          <div className={styles.section}>
            <h2 className={styles.sectionTitle}>Description</h2>
            <p className={styles.description}>{file.description}</p>
          </div>
        )}

        {file.tags && file.tags.length > 0 && (
          <div className={styles.section}>
            <h2 className={styles.sectionTitle}>Tags</h2>
            <div className={styles.tags}>
              {file.tags.map((tag) => (
                <span key={tag} className={styles.tag}>
                  {tag}
                </span>
              ))}
            </div>
          </div>
        )}

        <div className={styles.footer}>
          <span className={styles.uploader}>
            Uploaded by {file.uploaderName || 'Unknown'}
          </span>
          {isOwner && (
            <Link to="/dashboard" className={styles.manageLink}>
              Manage your files &rarr;
            </Link>
          )}
        </div>
      </div>
    </div>
  );
}
