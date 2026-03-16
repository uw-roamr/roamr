import { Link } from 'react-router-dom';
import { WasmFile } from '../../services/firestore';
import { formatFileSize } from '../../services/storage';
import styles from './WasmCard.module.css';

interface WasmCardProps {
  file: WasmFile;
  showActions?: boolean;
  onToggleVisibility?: (file: WasmFile) => void;
  onDelete?: (file: WasmFile) => void;
}

export function WasmCard({
  file,
  showActions = false,
  onToggleVisibility,
  onDelete,
}: WasmCardProps) {
  const uploadDate = file.uploadedAt?.toDate?.()
    ? file.uploadedAt.toDate().toLocaleDateString()
    : 'Unknown';

  return (
    <div className={styles.card}>
      <Link to={`/wasm/${file.id}`} className={styles.content}>
        <div className={styles.icon}>📦</div>
        <h3 className={styles.name}>{file.name}</h3>
        <p className={styles.fileName}>{file.fileName}</p>
        <p className={styles.description}>
          {file.description || 'No description'}
        </p>
        <div className={styles.meta}>
          <span className={styles.metaItem}>
            {formatFileSize(file.fileSize)}
          </span>
          <span className={styles.metaItem}>{uploadDate}</span>
          <span className={styles.metaItem}>
            {file.downloadCount} downloads
          </span>
        </div>
        <div className={styles.tags}>
          <span className={`${styles.tag} ${file.isPublic ? styles.public : styles.private}`}>
            {file.isPublic ? 'Public' : 'Private'}
          </span>
          {file.tags?.slice(0, 3).map((tag) => (
            <span key={tag} className={styles.tag}>
              {tag}
            </span>
          ))}
        </div>
      </Link>

      {showActions && (
        <div className={styles.actions}>
          <button
            className={styles.actionBtn}
            onClick={() => onToggleVisibility?.(file)}
            title={file.isPublic ? 'Make private' : 'Make public'}
          >
            {file.isPublic ? '🔒' : '🔓'}
          </button>
          <button
            className={`${styles.actionBtn} ${styles.deleteBtn}`}
            onClick={() => onDelete?.(file)}
            title="Delete"
          >
            🗑️
          </button>
        </div>
      )}

      <div className={styles.uploader}>
        by {file.uploaderName || 'Unknown'}
      </div>
    </div>
  );
}
