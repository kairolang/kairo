if [[ "$BRANCH" == "main" || "$BRANCH" == "beta" ]]; then
    echo "Error: Cannot proceed from main or beta branch"
    exit 1
fi

git checkout main
git merge canary
git push origin main
git checkout canary